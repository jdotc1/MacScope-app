#!/usr/bin/env python3

from __future__ import annotations

import importlib.util
import errno
import json
import os
import stat
import subprocess
import sys
import tempfile
import time
import unittest
from dataclasses import replace
from pathlib import Path
from types import SimpleNamespace
from unittest import mock


ROOT = Path(__file__).resolve().parents[2]
PATH = ROOT / "Scripts" / "debugger-fixture" / "candidate_drivers.py"
sys.path.insert(0, str(PATH.parent))
spec = importlib.util.spec_from_file_location("candidate_drivers", PATH)
assert spec and spec.loader
drivers = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = drivers
spec.loader.exec_module(drivers)


class FakeRunner:
    def __init__(self, results):
        self.results = list(results)
        self.calls = []

    def run(self, argv, *, env=None, timeout=15.0):
        self.calls.append((tuple(argv), env, timeout))
        result = self.results.pop(0)
        return drivers.CommandResult(tuple(argv), *result)


class MutableClock:
    def __init__(self): self.value = 1.0
    def __call__(self): return self.value
    def sleep(self, amount): self.value += amount


class FixtureControlTests(unittest.TestCase):
    @staticmethod
    def fifo_metadata(*, device=4, inode=9):
        return SimpleNamespace(
            st_mode=stat.S_IFIFO | 0o600,
            st_uid=os.geteuid(),
            st_dev=device,
            st_ino=inode,
        )

    def test_open_retries_delayed_path_and_reader_until_exact_fifo_is_admitted(self):
        clock = MutableClock()
        metadata = self.fifo_metadata()
        client = drivers.FixtureControlClient(
            Path("/tmp/control"), "helper", "N", 42,
            clock=clock, sleep=clock.sleep,
        )
        with (mock.patch.object(drivers.os, "lstat",
                                side_effect=[FileNotFoundError(), metadata, metadata]),
              mock.patch.object(drivers.os, "open",
                                side_effect=[OSError(errno.ENXIO, "no reader"), 17]) as opener,
              mock.patch.object(drivers.os, "fstat", return_value=metadata)):
            client.open(timeout=0.1)

        self.assertEqual(client._command_fd, 17)
        self.assertEqual(opener.call_count, 2)
        self.assertGreater(clock.value, 1.0)

    def test_open_times_out_at_bounded_deadline_when_fifo_path_never_appears(self):
        clock = MutableClock()
        client = drivers.FixtureControlClient(
            Path("/tmp/control"), "helper", "N", 42,
            clock=clock, sleep=clock.sleep,
        )
        with mock.patch.object(drivers.os, "lstat", side_effect=FileNotFoundError()):
            with self.assertRaisesRegex(TimeoutError, "command FIFO admission timed out"):
                client.open(timeout=0.025)
        self.assertGreaterEqual(clock.value, 1.025)

    def test_open_is_idempotent_and_uses_nonblocking_safe_descriptor_flags(self):
        metadata = self.fifo_metadata()
        client = drivers.FixtureControlClient(Path("/tmp/control"), "helper", "N", 42)
        with (mock.patch.object(drivers.os, "lstat", return_value=metadata),
              mock.patch.object(drivers.os, "open", return_value=17) as opener,
              mock.patch.object(drivers.os, "fstat", return_value=metadata),
              mock.patch.object(drivers.os, "close") as closer):
            client.open(timeout=0.1)
            client.open(timeout=0.1)
            client.close()

        self.assertEqual(opener.call_count, 1)
        opened_path, flags = opener.call_args.args
        self.assertEqual(opened_path, client.command_path)
        self.assertTrue(flags & os.O_WRONLY)
        self.assertTrue(flags & os.O_NONBLOCK)
        for optional_flag in ("O_CLOEXEC", "O_NOFOLLOW"):
            value = getattr(os, optional_flag, 0)
            if value:
                self.assertTrue(flags & value)
        closer.assert_called_once_with(17)

    def test_open_rejects_unrelated_os_error_without_retry(self):
        clock = MutableClock()
        metadata = self.fifo_metadata()
        client = drivers.FixtureControlClient(
            Path("/tmp/control"), "helper", "N", 42,
            clock=clock, sleep=clock.sleep,
        )
        with (mock.patch.object(drivers.os, "lstat", return_value=metadata),
              mock.patch.object(drivers.os, "open",
                                side_effect=PermissionError(errno.EACCES, "denied")) as opener):
            with self.assertRaisesRegex(drivers.DriverError,
                                        "unable to open fixture command FIFO"):
                client.open(timeout=0.1)
        self.assertEqual(opener.call_count, 1)
        self.assertEqual(clock.value, 1.0)

    def test_persistent_fifo_writer_reuses_one_exact_descriptor_across_commands(self):
        metadata = self.fifo_metadata()
        writes = []
        client = drivers.FixtureControlClient(Path("/tmp/control"), "helper", "N", 42)
        with (mock.patch.object(drivers.os, "lstat", return_value=metadata),
              mock.patch.object(drivers.os, "open", return_value=17) as opener,
              mock.patch.object(drivers.os, "fstat", return_value=metadata),
              mock.patch.object(drivers.os, "write",
                                side_effect=lambda descriptor, payload:
                                writes.append((descriptor, payload)) or len(payload)),
              mock.patch.object(drivers.os, "close")):
            client._write_persistent_fifo(client.command_path, b"one\n")
            client._write_persistent_fifo(client.command_path, b"two\n")
            client.close()

        self.assertEqual(opener.call_count, 1)
        self.assertEqual(writes, [(17, b"one\n"), (17, b"two\n")])

    def test_production_client_keeps_compiled_fixture_alive_for_multiple_commands(self):
        source = ROOT / "Scripts" / "debugger-fixture" / "Sources"
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            helper = root / "helper"
            compiled = subprocess.run(
                ["/usr/bin/xcrun", "--sdk", "macosx", "clang", "-O0",
                 str(source / "helper.c"), str(source / "fixture_runtime.c"),
                 "-o", str(helper)],
                capture_output=True, text=True, check=False,
            )
            self.assertEqual(compiled.returncode, 0, compiled.stderr)
            started_after_ns = time.time_ns()
            control = root / "control"
            control.mkdir(mode=0o700)
            process = subprocess.Popen(
                [str(helper), "--control-dir", str(control), "--nonce", "N",
                 "--started-after-ns", str(started_after_ns)],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, text=True,
            )
            client = drivers.FixtureControlClient(control, "helper", "N", process.pid)
            try:
                deadline = time.monotonic() + 3.0
                while not client.command_path.exists() and time.monotonic() < deadline:
                    time.sleep(0.01)
                self.assertTrue(client.command_path.exists())
                first = client.send("checkpoint", timeout=3.0)
                second = client.send("checkpoint", timeout=3.0)
                self.assertEqual((first["commandSequence"], second["commandSequence"]), (1, 2))
                exited = client.send("exit", timeout=3.0)
                self.assertEqual(exited["commandSequence"], 3)
                self.assertEqual(process.wait(timeout=3.0), 0)
                self.assertNotIn("commandEOF", client.event_path.read_text(encoding="utf-8"))
            finally:
                client.close()
                if process.poll() is None:
                    process.terminate()
                    process.wait(timeout=3.0)

    def test_writes_canonical_command_and_accepts_only_correlated_monotonic_event(self):
        clock = MutableClock()
        writes = []
        events = []
        def writer(path, payload):
            writes.append((path, payload))
            events.append((json.dumps({"schema": 1, "sequence": 2, "commandSequence": 1,
                "nonce": "N", "role": "helper", "pid": 42, "operation": "checkpoint",
                "result": "ok"}) + "\n").encode())
        client = drivers.FixtureControlClient(Path("/tmp/control"), "helper", "N", 42,
            clock=clock, sleep=clock.sleep, writer=writer, reader=lambda _: events[-1])
        response = client.send("checkpoint")
        self.assertEqual(response["commandSequence"], 1)
        self.assertEqual(json.loads(writes[0][1]), {"nonce": "N", "operation": "checkpoint",
                                                   "schema": 1, "sequence": 1})
        self.assertEqual(client.next_command_sequence, 2)

    def test_rejects_wrong_identity_and_nonmonotonic_events(self):
        clock = MutableClock()
        wrong = {"schema": 1, "sequence": 1, "commandSequence": 1, "nonce": "wrong",
                 "role": "helper", "pid": 42, "operation": "checkpoint", "result": "ok"}
        client = drivers.FixtureControlClient(Path("/tmp/control"), "helper", "N", 42,
            clock=clock, sleep=clock.sleep, writer=lambda *_: None,
            reader=lambda _: (json.dumps(wrong) + "\n").encode())
        with self.assertRaisesRegex(drivers.DriverError, "identity mismatch"):
            client.send("checkpoint")

    def test_production_event_reader_rejects_oversize_before_path_allocation(self):
        with tempfile.TemporaryDirectory() as directory:
            control = Path(directory)
            event_path = control / "helper.events.jsonl"
            with event_path.open("wb") as stream:
                stream.truncate(drivers.MAX_FIXTURE_EVENT_BYTES + 1)
            event_path.chmod(0o600)
            client = drivers.FixtureControlClient(control, "helper", "N", 42)

            with mock.patch.object(
                    Path, "read_bytes",
                    side_effect=AssertionError("unbounded Path.read_bytes used")):
                with self.assertRaisesRegex(
                        drivers.DriverError, "exceeds configured bound"):
                    client._events()

    def test_production_event_reader_rejects_symlink(self):
        with tempfile.TemporaryDirectory() as directory:
            control = Path(directory)
            target = control / "target"
            target.write_bytes(b"{}\n")
            target.chmod(0o600)
            (control / "helper.events.jsonl").symlink_to(target)
            client = drivers.FixtureControlClient(control, "helper", "N", 42)
            with self.assertRaisesRegex(
                    drivers.DriverError, "unable to open secure fixture event stream"):
                client._events()

    def test_production_event_reader_treats_delayed_file_as_no_events(self):
        with tempfile.TemporaryDirectory() as directory:
            client = drivers.FixtureControlClient(
                Path(directory), "helper", "N", 42)
            self.assertEqual(client._events(), [])


class EvidenceTests(unittest.TestCase):
    def test_negative_evidence_is_bounded_hashed_and_structured(self):
        evidence = drivers.NegativeEvidence.from_text("timedOut", "attach", "x" * 5000, 9)
        self.assertTrue(evidence.diagnosticTruncated)
        self.assertEqual(len(evidence.diagnosticPreview.encode()), drivers.MAX_DIAGNOSTIC_BYTES)
        self.assertEqual(len(evidence.diagnosticSHA256), 64)
        self.assertEqual(evidence.returnCode, 9)


class DAPDriverTests(unittest.TestCase):
    def acknowledgement_for_protocol(self, protocol, request, command):
        result = protocol.result_for(request["seq"])
        acknowledgement = drivers.DAPRequestAcknowledgement(
            response=result.response,
            requestSequence=request["seq"],
            command=command,
            sessionEpoch=result.session_epoch,
            lifecycleRevision=result.lifecycle_revision,
            stopRevision=result.stop_revision,
            acceptedEvents=tuple(
                drivers.DAPAcceptedEvent(
                    eventSequence=envelope.message["seq"],
                    eventName=envelope.message["event"],
                    sessionEpoch=envelope.session_epoch,
                    lifecycleRevision=envelope.lifecycle_revision,
                    stopRevision=envelope.stop_revision,
                )
                for envelope in protocol.events
            ),
        )
        if not hasattr(self, "protocols"):
            self.protocols = {}
        self.protocols[id(acknowledgement)] = protocol
        return acknowledgement

    def live_attach_acknowledgement(self):
        clock = MutableClock()
        protocol = drivers.dap.DAPSession(session_epoch=3, clock=clock)
        request = protocol.make_request("attach", {"pid": 7})
        protocol.receive({"seq": 1, "type": "response", "request_seq": request["seq"],
                          "command": "attach", "success": True}, session_epoch=3)
        protocol.receive({"seq": 2, "type": "event", "event": "process",
                          "body": {"systemProcessId": 7}}, session_epoch=3)
        protocol.receive({"seq": 3, "type": "event", "event": "stopped",
                          "body": {"reason": "entry", "threadId": 11}}, session_epoch=3)
        return self.acknowledgement_for_protocol(protocol, request, "attach")

    def test_attach_proof_must_bind_current_session_event_and_core_state(self):
        acknowledgement = self.live_attach_acknowledgement()
        self.assertFalse(hasattr(acknowledgement, "protocol"))
        self.assertEqual(
            [event.eventName for event in acknowledgement.acceptedEvents],
            ["process", "stopped"],
        )
        valid = drivers.DAPPostconditionProof(
            operation="attach", requestSequence=1, sessionEpoch=3,
            lifecycleRevision=2, stopRevision=1, acceptedEventSequence=3,
            acceptedEventName="stopped", targetPID=7, identityMatched=True,
            condition="exact target process and entry stop observed",
            evidence={"processId": 7},
        )
        result = self.driver(acknowledgement, valid).attach("R", 7)
        self.assertEqual(result.observation, "observed")
        self.assertEqual(
            self.protocols[id(acknowledgement)].result_for(1).state,
            drivers.dap.RequestState.OBSERVED,
        )

        forged_acknowledgement = self.live_attach_acknowledgement()
        forged = drivers.DAPPostconditionProof(
            operation="attach", requestSequence=1, sessionEpoch=3,
            lifecycleRevision=999, stopRevision=999, acceptedEventSequence=999,
            acceptedEventName="stopped", targetPID=7, identityMatched=True,
            condition="fabricated future revisions", evidence={"processId": 7},
        )
        forged_result = self.driver(forged_acknowledgement, forged).attach("R", 7)
        self.assertNotEqual(forged_result.observation, "observed")
        self.assertEqual(
            self.protocols[id(forged_acknowledgement)].result_for(1).state,
            drivers.dap.RequestState.ACKNOWLEDGED,
        )

        stale_acknowledgement = self.live_attach_acknowledgement()
        stale_protocol = self.protocols[id(stale_acknowledgement)]
        stale_acknowledgement = replace(stale_acknowledgement, requestEventBoundary=3)
        self.protocols[id(stale_acknowledgement)] = stale_protocol
        stale_result = self.driver(stale_acknowledgement, valid).attach("R", 7)
        self.assertNotEqual(stale_result.observation, "observed")
        self.assertEqual(stale_protocol.result_for(1).state,
                         drivers.dap.RequestState.ACKNOWLEDGED)

    def acknowledgement(self, *, process_id=7):
        return self.live_attach_acknowledgement()

    def live_disconnect_acknowledgement(self):
        clock = MutableClock()
        protocol = drivers.dap.DAPSession(session_epoch=3, clock=clock)
        request = protocol.make_request("disconnect", {"terminateDebuggee": False})
        protocol.receive({"seq": 1, "type": "response", "request_seq": request["seq"],
                          "command": "disconnect", "success": True}, session_epoch=3)
        protocol.receive({"seq": 2, "type": "event", "event": "process",
                          "body": {"systemProcessId": 7}}, session_epoch=3)
        protocol.receive({"seq": 3, "type": "event", "event": "terminated"},
                         session_epoch=3)
        return self.acknowledgement_for_protocol(protocol, request, "disconnect")

    def proof(self, operation="attach", *, process_id=7):
        return drivers.DAPPostconditionProof(
            operation=operation,
            requestSequence=1,
            sessionEpoch=3,
            lifecycleRevision=2,
            stopRevision=0 if operation == "disconnect" else 1,
            targetPID=process_id,
            identityMatched=True,
            condition="exact target identity and stopped state proven",
            evidence={"processId": process_id, "nonce": "N"},
            acceptedEventSequence=3,
            acceptedEventName="terminated" if operation == "disconnect" else "stopped",
        )

    def driver(self, acknowledgement, proof=None):
        instance = object.__new__(drivers.LldbDAPDriver)
        instance.runner = None
        instance.path = Path("/Xcode/lldb-dap")
        protocol = getattr(self, "protocols", {}).get(id(acknowledgement))
        instance._session = SimpleNamespace(protocol=protocol) if protocol else None
        instance.request = lambda *args: acknowledgement
        instance.observe = lambda operation, response, pid: proof or self.proof(operation, process_id=pid)
        return instance

    def test_attach_requires_explicit_pid_proof(self):
        mismatch = self.driver(self.acknowledgement(), self.proof(process_id=8))
        result = mismatch.attach("R", 7)
        self.assertEqual(result.observation, "identityMismatch")
        self.assertEqual(result.targetDisposition, "targetDispositionUnknown")
        matching = self.driver(self.acknowledgement(), self.proof(process_id=7))
        self.assertEqual(matching.attach("R", 7).observation, "observed")

    def test_detach_is_nonterminating_and_requires_post_detach_fixture_control(self):
        acknowledgement = self.live_disconnect_acknowledgement()
        dap = self.driver(acknowledgement, self.proof("disconnect"))
        class Control:
            def send(self, operation):
                self.operation = operation
                return {"operation": operation, "pid": 7, "commandSequence": 3}
        control = Control()
        result = dap.detach("D", 7, control)
        self.assertEqual(control.operation, "checkpoint")
        self.assertEqual(result.targetDisposition, "detached")
        self.assertEqual(result.proof["postDetachControl"]["pid"], 7)
        self.assertEqual(result.proof["requestArguments"], {"terminateDebuggee": False})

    def test_each_start_uses_fresh_initialized_adapter_and_disconnect_reuses_attach_session(self):
        calls = []
        class Session:
            def __init__(self, identity):
                self.identity = identity
            def acknowledgement(self, command):
                return drivers.DAPRequestAcknowledgement(
                    {"success": True}, 2, command, self.identity, 0, 0,
                )
            def initialize(self, arguments, timeout):
                calls.append((self.identity, "initialize"))
                return self.acknowledgement("initialize")
            def start(self, command, arguments, timeout):
                calls.append((self.identity, command, dict(arguments)))
                return self.acknowledgement(command)
            def disconnect(self, timeout, *, terminate_debuggee):
                calls.append((self.identity, "disconnect", terminate_debuggee))
                return self.acknowledgement("disconnect")
            def close(self):
                calls.append((self.identity, "close"))
                return {"role": "adapter", "registration": "A", "complete": True}
        dap = object.__new__(drivers.LldbDAPDriver)
        dap.runner = None
        dap.path = Path("/Xcode/lldb-dap")
        dap._session = None
        sessions = []
        def factory(_):
            session = Session(len(sessions) + 1)
            sessions.append(session)
            return session
        dap._session_factory = factory
        dap.request = dap._live_request
        dap._live_request(dap.path, "attach", {"pid": 7, "stopOnEntry": True}, 1.0)
        dap._live_request(dap.path, "disconnect", {"terminateDebuggee": False}, 1.0)
        dap._live_request(dap.path, "attach", {"pid": 8, "stopOnEntry": True}, 1.0)
        receipt = dap.close()
        self.assertEqual(len(sessions), 2)
        self.assertEqual(calls, [
            (1, "initialize"), (1, "attach", {"pid": 7, "stopOnEntry": True}),
            (1, "disconnect", False), (1, "close"),
            (2, "initialize"), (2, "attach", {"pid": 8, "stopOnEntry": True}),
            (2, "close"),
        ])
        self.assertTrue(receipt["complete"])

    def test_launch_terminal_disconnect_requests_debuggee_termination(self):
        calls = []
        class Session:
            def initialize(self, arguments, timeout):
                return drivers.DAPRequestAcknowledgement(
                    {"success": True}, 1, "initialize", 1, 0, 0,
                )
            def start(self, command, arguments, timeout):
                return drivers.DAPRequestAcknowledgement(
                    {"success": True}, 2, command, 1, 1, 1,
                )
            def disconnect(self, timeout, *, terminate_debuggee):
                calls.append((terminate_debuggee, timeout))
                return drivers.DAPRequestAcknowledgement(
                    {"success": True}, 3, "disconnect", 1, 2, 1,
                )
            def close(self):
                return {"role": "adapter", "registration": "A", "complete": True}
        dap = object.__new__(drivers.LldbDAPDriver)
        dap.runner = None
        dap.path = Path("/Xcode/lldb-dap")
        dap._session = None
        dap._session_factory = lambda _: Session()
        dap.request = dap._live_request
        dap._live_request(dap.path, "launch", {"program": "/tmp/app", "stopOnEntry": True}, 1.0)

        acknowledgement = dap._live_request(
            dap.path, "disconnect", {"terminateDebuggee": True}, 1.0,
        )

        self.assertTrue(acknowledgement.response["success"])
        self.assertEqual(calls, [(True, 1.0)])

        with self.assertRaisesRegex(
            drivers.DriverError, "exact boolean termination policy"
        ):
            dap._live_request(
                dap.path, "disconnect", {"terminateDebuggee": 1}, 1.0,
            )

    def test_protocol_success_without_postcondition_is_not_observed(self):
        dap = self.driver(self.acknowledgement())
        dap.observe = None
        result = dap.attach("owned-R", 7)
        self.assertEqual(result.observation, "notAttempted")
        self.assertEqual(result.targetDisposition, "targetDispositionUnknown")
        self.assertEqual(result.proof["acknowledgement"]["requestId"], "owned-R")

    def test_untyped_or_revision_mismatched_postcondition_cannot_promote(self):
        dap = self.driver(self.acknowledgement())
        dap.observe = lambda *_: {"processId": 7}
        self.assertEqual(dap.attach("A", 7).observation, "harnessError")

        bad = self.proof()
        bad = drivers.DAPPostconditionProof(
            bad.operation, bad.requestSequence, 99, bad.lifecycleRevision,
            bad.stopRevision, bad.targetPID, bad.identityMatched,
            bad.condition, bad.evidence,
        )
        self.assertEqual(self.driver(self.acknowledgement(), bad).attach("A", 7).observation,
                         "identityMismatch")

    def test_detach_preserves_negative_transport_outcome(self):
        failed = drivers.DAPRequestAcknowledgement(
            {"seq": 9, "type": "response", "request_seq": 1,
             "command": "disconnect", "success": False},
            1, "disconnect", 3, 2, 1,
        )
        dap = self.driver(failed, self.proof("disconnect"))
        class Control:
            def send(self, operation):
                raise AssertionError("failed disconnect must not checkpoint")
        result = dap.detach("D", 7, Control())
        self.assertEqual(result.observation, "protocolError")
        self.assertEqual(result.targetDisposition, "targetDispositionUnknown")


class DAPProcessSessionTests(unittest.TestCase):
    class Sink:
        def __init__(self, on_message=None):
            self.value = bytearray()
            self.closed = False
            self.parser = drivers.dap.DAPFrameParser()
            self.on_message = on_message
        def write(self, data):
            count = min(3, len(data))
            self.value.extend(data[:count])
            for message in self.parser.feed(bytes(data[:count])):
                if self.on_message is not None:
                    self.on_message(message)
            return count
        def flush(self): pass
        def close(self): self.closed = True

    class Process:
        def __init__(self, stdout, stderr):
            self.pid = 4321
            self.stdin = DAPProcessSessionTests.Sink()
            self.stdout = stdout
            self.stderr = stderr

    class Lifecycle:
        def __init__(self, process, *, complete=True):
            self.process = process
            self.complete = complete
            self.spawned = []
            self.cleaned = []
        def spawn_and_register(self, adapter):
            self.spawned.append(adapter)
            return self.process, "registration-A"
        def cleanup_adapter(self, registration):
            self.cleaned.append(registration)
            return {"role": "adapter", "registration": registration,
                    "complete": self.complete}

    def make_session(self, response, *, stderr=b"", complete=True):
        stdout_read, stdout_write = os.pipe()
        stderr_read, stderr_write = os.pipe()
        os.write(stdout_write, drivers.dap.encode_frame(response))
        os.close(stdout_write)
        if stderr:
            os.write(stderr_write, stderr)
        os.close(stderr_write)
        process = self.Process(os.fdopen(stdout_read, "rb", buffering=0),
                               os.fdopen(stderr_read, "rb", buffering=0))
        lifecycle = self.Lifecycle(process, complete=complete)
        session = drivers.DAPProcessSession(Path("/Xcode/lldb-dap"),
            adapter_lifecycle=lifecycle, session_epoch=4, diagnostic_capacity=8)
        return session, lifecycle, process

    def make_interactive_session(self, handler):
        stdout_read, stdout_write = os.pipe()
        stderr_read, stderr_write = os.pipe()
        os.close(stderr_write)

        def receive_request(message):
            for reply in handler(message):
                frame = drivers.dap.encode_frame(reply)
                # Fragment every reply at a non-header boundary.
                os.write(stdout_write, frame[:7])
                os.write(stdout_write, frame[7:])

        process = self.Process(os.fdopen(stdout_read, "rb", buffering=0),
                               os.fdopen(stderr_read, "rb", buffering=0))
        process.stdin = self.Sink(receive_request)
        lifecycle = self.Lifecycle(process)
        session = drivers.DAPProcessSession(Path("/Xcode/lldb-dap"),
            adapter_lifecycle=lifecycle, session_epoch=4)
        return session, lifecycle, process, stdout_write

    def test_async_attach_waits_for_configuration_process_and_later_stop(self):
        incoming = 0
        def message(kind, field, value, **extra):
            nonlocal incoming
            incoming += 1
            envelope = {"seq": incoming, "type": kind, field: value}
            envelope.update(extra)
            return envelope
        def handler(request):
            command = request["command"]
            if command == "initialize":
                return [message("response", "command", command,
                    request_seq=request["seq"], success=True)]
            if command == "attach":
                self.assertTrue(request["arguments"]["stopOnEntry"])
                return [message("event", "event", "initialized")]
            if command == "configurationDone":
                return [
                    message("response", "command", command,
                            request_seq=request["seq"], success=True),
                    message("event", "event", "process", body={
                        "systemProcessId": 4242, "startMethod": "attach",
                        "isLocalProcess": True}),
                    message("response", "command", "attach", request_seq=2, success=True),
                    message("event", "event", "stopped", body={"reason": "entry"}),
                ]
            return []
        session, _, process, writer = self.make_interactive_session(handler)
        try:
            session.initialize({"adapterID": "lldb-dap"}, 1.0)
            acknowledgement = session.start(
                "attach", {"pid": 4242, "stopOnEntry": True}, 1.0
            )
            facts = acknowledgement.protocolFacts
            self.assertEqual(facts.process.systemProcessId, 4242)
            self.assertGreater(facts.stopped.eventSequence, facts.process.eventSequence)
            parser = drivers.dap.DAPFrameParser()
            commands = [item["command"] for item in parser.feed(bytes(process.stdin.value))]
            self.assertEqual(commands, ["initialize", "attach", "configurationDone"])
        finally:
            session.close()
            os.close(writer)

    def test_xcode_zero_sequences_are_normalized_at_process_boundary(self):
        def message(kind, field, value, **extra):
            envelope = {"seq": 0, "type": kind, field: value}
            envelope.update(extra)
            return envelope

        def handler(request):
            command = request["command"]
            if command == "initialize":
                return [message("response", "command", command,
                    request_seq=request["seq"], success=True)]
            if command == "attach":
                return [message("event", "event", "initialized")]
            if command == "configurationDone":
                return [
                    message("response", "command", command,
                            request_seq=request["seq"], success=True),
                    message("event", "event", "process", body={
                        "systemProcessId": 4242, "startMethod": "attach",
                        "isLocalProcess": True}),
                    message("response", "command", "attach", request_seq=2, success=True),
                    message("event", "event", "stopped", body={"reason": "entry"}),
                ]
            return []

        session, _, _, writer = self.make_interactive_session(handler)
        try:
            session.initialize({"adapterID": "lldb-dap"}, 1.0)
            acknowledgement = session.start(
                "attach", {"pid": 4242, "stopOnEntry": True}, 1.0
            )
            self.assertEqual(acknowledgement.response["rawAdapterSequence"], 0)
            event_sequences = [event.eventSequence for event in acknowledgement.acceptedEvents]
            self.assertEqual(event_sequences, sorted(set(event_sequences)))
            self.assertTrue(all(sequence > 0 for sequence in event_sequences))
            self.assertTrue(all(
                envelope.message["rawAdapterSequence"] == 0
                for envelope in session.events
            ))
        finally:
            session.close()
            os.close(writer)

    def test_adapter_sequence_mode_cannot_switch_after_first_message(self):
        replies = iter((0, 2))

        def handler(request):
            return [{"seq": next(replies), "type": "response",
                     "request_seq": request["seq"], "command": request["command"],
                     "success": True}]

        session, _, _, writer = self.make_interactive_session(handler)
        try:
            session.request("threads", {}, 1.0)
            with self.assertRaisesRegex(
                drivers.dap.DAPProtocolError, "adapter sequence mode changed"
            ):
                session.request("modules", {}, 1.0)
        finally:
            session.close()
            os.close(writer)

    def test_uses_hardened_framing_correlation_and_partial_write_loop(self):
        response = {"seq": 10, "type": "response", "request_seq": 1,
                    "command": "threads", "success": True}
        session, lifecycle, process = self.make_session(response)
        acknowledgement = session.request("threads", {}, 1.0)
        self.assertEqual(acknowledgement.command, "threads")
        self.assertEqual(acknowledgement.sessionEpoch, 4)
        self.assertEqual(acknowledgement.response["seq"], 10)
        self.assertNotIn("rawAdapterSequence", acknowledgement.response)
        parser = drivers.dap.DAPFrameParser()
        self.assertEqual(parser.feed(bytes(process.stdin.value))[0]["command"], "threads")
        receipt = session.close()
        self.assertEqual(lifecycle.cleaned, ["registration-A"])
        self.assertTrue(receipt["complete"])

    def test_close_keeps_all_adapter_pipes_open_until_exact_cleanup_completes(self):
        response = {"seq": 10, "type": "response", "request_seq": 1,
                    "command": "threads", "success": True}
        session, lifecycle, process = self.make_session(response)
        observed = []

        def cleanup(registration):
            observed.append((
                process.stdin.closed,
                process.stdout.closed,
                process.stderr.closed,
            ))
            return {"role": "adapter", "registration": registration,
                    "complete": True}

        lifecycle.cleanup_adapter = cleanup

        session.close()

        self.assertEqual(observed, [(False, False, False)])
        self.assertTrue(process.stdin.closed)
        self.assertTrue(process.stdout.closed)
        self.assertTrue(process.stderr.closed)

    def test_close_closes_all_adapter_pipes_after_exact_cleanup_failure(self):
        response = {"seq": 10, "type": "response", "request_seq": 1,
                    "command": "threads", "success": True}
        session, lifecycle, process = self.make_session(response)
        observed = []

        def cleanup(registration):
            observed.append((
                process.stdin.closed,
                process.stdout.closed,
                process.stderr.closed,
            ))
            raise RuntimeError("exact cleanup failed")

        lifecycle.cleanup_adapter = cleanup

        with self.assertRaisesRegex(RuntimeError, "exact cleanup failed"):
            session.close()

        self.assertEqual(observed, [(False, False, False)])
        self.assertTrue(process.stdin.closed)
        self.assertTrue(process.stdout.closed)
        self.assertTrue(process.stderr.closed)

    def test_rejects_response_command_mismatch(self):
        response = {"seq": 10, "type": "response", "request_seq": 1,
                    "command": "modules", "success": True}
        session, _, _ = self.make_session(response)
        with self.assertRaisesRegex(drivers.dap.DAPProtocolError, "command mismatch"):
            session.request("threads", {}, 1.0)
        session.close()

    def test_stderr_is_bounded_and_close_requires_exact_complete_receipt(self):
        response = {"seq": 10, "type": "response", "request_seq": 1,
                    "command": "threads", "success": True}
        session, _, _ = self.make_session(response, stderr=b"abcdefghijkl", complete=False)
        session.request("threads", {}, 1.0)
        with self.assertRaisesRegex(drivers.DriverError, "cleanup receipt"):
            session.close()
        self.assertEqual(session.stderr_output.value(), b"efghijkl")
        self.assertEqual(session.stderr_output.dropped_bytes, 4)

    def test_registered_adapter_is_cleaned_if_pipe_validation_fails(self):
        process = self.Process(None, None)
        process.stderr = None
        lifecycle = self.Lifecycle(process)
        with self.assertRaisesRegex(drivers.DriverError, "requires stdin, stdout, and stderr"):
            drivers.DAPProcessSession(
                Path("/Xcode/lldb-dap"), adapter_lifecycle=lifecycle
            )
        self.assertEqual(lifecycle.cleaned, ["registration-A"])


class CLIDriverTests(unittest.TestCase):
    def test_lldb_quote_escapes_expression_substitution(self):
        self.assertEqual(drivers._lldb_quote('`1+1`'), '"\\`1+1\\`"')

    def driver(self, result):
        instance = object.__new__(drivers.LldbCLIDriver)
        instance.runner = FakeRunner([result])
        instance.path = Path("/Xcode/lldb")
        instance.session_lifecycle = None
        instance.observe = lambda operation, result, pid: drivers.CLIPostconditionProof(
            operation, pid or 42, "/tmp/helper", "N", True, operation,
            {"processId": pid or 42})
        return instance

    def test_attach_rejects_success_without_exact_lldb_pid_proof(self):
        result = self.driver((0, "Process 99 stopped", "")).attach("A", 42)
        self.assertEqual(result.observation, "identityMismatch")

    def test_cli_detach_requires_ack_and_post_detach_control(self):
        cli = self.driver((0, "Process 42 detached", ""))
        class Control:
            def send(self, operation): return {"operation": operation, "pid": 42}
        result = cli.detach("D", 42, Control())
        self.assertEqual(result.observation, "observed")
        self.assertEqual(result.targetDisposition, "detached")

    def test_combined_attach_detach_uses_one_lldb_subprocess(self):
        cli = self.driver((0, "Process 42 stopped\nProcess 42 detached", ""))
        class Control:
            def send(self, operation): return {"operation": operation, "pid": 42}
        attached, detached = cli.attach_and_detach("A", "D", 42, Control())
        self.assertEqual((attached.observation, detached.observation), ("observed", "observed"))
        self.assertEqual(len(cli.runner.calls), 1)
        command = cli.runner.calls[0][0]
        self.assertIn("process attach --pid 42", command)
        self.assertIn("process detach", command)

    def test_live_cli_requires_registered_cleanup_lifecycle(self):
        cli = object.__new__(drivers.LldbCLIDriver)
        cli.runner = drivers.SubprocessRunner()
        cli.path = Path("/Xcode/lldb")
        cli.observe = None
        cli.session_lifecycle = None
        with self.assertRaisesRegex(drivers.DriverError, "registered session lifecycle"):
            cli._run_commands(("version",))

    def test_cli_lifecycle_requires_complete_exact_receipt(self):
        cli = object.__new__(drivers.LldbCLIDriver)
        cli.runner = FakeRunner([])
        cli.path = Path("/Xcode/lldb")
        cli.observe = None
        class Lifecycle:
            def execute_and_cleanup(self, argv, timeout):
                return drivers.CommandResult(tuple(argv), 0, "ok", ""), {
                    "role": "adapter", "registration": "A", "complete": False}
        cli.session_lifecycle = Lifecycle()
        with self.assertRaisesRegex(drivers.DriverError, "cleanup receipt"):
            cli._run_commands(("version",))


class PythonDiscoveryTests(unittest.TestCase):
    def driver(self, runner):
        instance = object.__new__(drivers.LldbPythonJSONDriver)
        instance.runner = runner
        instance.lldb_path = Path("/Xcode/lldb")
        return instance

    def test_discovery_returns_structural_unsupported_evidence(self):
        discovery = self.driver(FakeRunner([(1, "", "missing")])).discover()
        self.assertFalse(discovery.supported)
        self.assertEqual(discovery.evidence["negative"]["classification"], "unsupported")

    def test_discovery_records_successful_selected_xcode_import(self):
        runner = FakeRunner([(0, "/Xcode/LLDB/Python", ""),
                             (0, '{"version":"lldb-2700"}\n', "")])
        discovery = self.driver(runner).discover()
        self.assertFalse(discovery.supported)
        self.assertEqual(discovery.version, "lldb-2700")
        self.assertTrue(discovery.evidence["importAvailable"])
        self.assertFalse(discovery.evidence["typedOperationBridge"])
        self.assertEqual(runner.calls[1][1]["PYTHONPATH"], "/Xcode/LLDB/Python")


class OrchestrationTests(unittest.TestCase):
    def test_exact_attach_detach_revalidates_before_and_after(self):
        target = drivers.ExactAttachTarget(42, 123, 501, 501, "/tmp/helper", 0, 0,
            "exec", 1, 2, "UUID", "signer", "N")
        class Control:
            pid, nonce = 42, "N"
        class Driver:
            candidate = "candidate"
            def attach(self, request, pid):
                return drivers.CandidateOperationEvidence(self.candidate, "attach", "observed",
                    request, pid, "running", {"processId": pid})
            def detach(self, request, pid, control):
                return drivers.CandidateOperationEvidence(self.candidate, "detach", "observed",
                    request, pid, "detached", {"checkpoint": True})
        validations = []
        evidence = drivers.CandidateOrchestrator.attach_and_detach(
            Driver(), "R", target, Control(), lambda value: validations.append(value) or True)
        self.assertEqual([item.operation for item in evidence], ["attach", "detach"])
        self.assertEqual(validations, [target, target])


if __name__ == "__main__":
    unittest.main()
