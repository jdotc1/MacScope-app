#!/usr/bin/env python3

from __future__ import annotations

import io
import json
import sys
import threading
import unittest
from pathlib import Path


FIXTURE_ROOT = Path(__file__).resolve().parents[1] / "debugger-fixture"
sys.path.insert(0, str(FIXTURE_ROOT))

import dap_transport as dap  # noqa: E402


def wire(message: dict[str, object]) -> bytes:
    body = json.dumps(message, separators=(",", ":")).encode("utf-8")
    return f"Content-Length: {len(body)}\r\n\r\n".encode("ascii") + body


class MutableClock:
    def __init__(self) -> None:
        self.value = 10.0

    def __call__(self) -> float:
        return self.value


class FramingTests(unittest.TestCase):
    def test_fragmented_and_coalesced_frames_round_trip(self) -> None:
        first = {"seq": 1, "type": "event", "event": "initialized"}
        second = {"seq": 2, "type": "event", "event": "stopped"}
        encoded = dap.encode_frame(first) + dap.encode_frame(second)
        parser = dap.DAPFrameParser()
        self.assertEqual(parser.feed(encoded[:9]), [])
        self.assertEqual(parser.feed(encoded[9:]), [first, second])
        parser.finish()

    def test_complete_oversized_header_is_rejected_before_body_parsing(self) -> None:
        parser = dap.DAPFrameParser(max_header_bytes=24)
        with self.assertRaisesRegex(dap.DAPProtocolError, "header exceeds"):
            parser.feed(b"X-Filler: 1234567890\r\nContent-Length: 2\r\n\r\n{}")

    def test_eof_rejects_truncated_header_and_body(self) -> None:
        header = dap.DAPFrameParser()
        header.feed(b"Content-Length: 2\r\n")
        with self.assertRaisesRegex(dap.DAPProtocolError, "truncated header"):
            header.finish()

        body = dap.DAPFrameParser()
        body.feed(b"Content-Length: 5\r\n\r\n{}")
        with self.assertRaisesRegex(dap.DAPProtocolError, "truncated body"):
            body.finish()

    def test_rejects_conflicting_length_bad_json_and_trailing_body_bytes(self) -> None:
        parser = dap.DAPFrameParser()
        with self.assertRaisesRegex(dap.DAPProtocolError, "exactly one"):
            parser.feed(b"Content-Length: 2\r\nContent-Length: 3\r\n\r\n{}")
        with self.assertRaisesRegex(dap.DAPProtocolError, "UTF-8 JSON"):
            dap.DAPFrameParser().feed(b"Content-Length: 1\r\n\r\n{")
        with self.assertRaisesRegex(dap.DAPProtocolError, "body length"):
            dap.encode_frame({"type": "event"}, max_body_bytes=2)


class ChunkedSink:
    def __init__(self, chunk_size: int = 3) -> None:
        self.chunk_size = chunk_size
        self.value = bytearray()
        self.flushes = 0
        self.active_writers = 0
        self.concurrent_write = False
        self.lock = threading.Lock()

    def write(self, data: bytes) -> int:
        with self.lock:
            self.active_writers += 1
            if self.active_writers != 1:
                self.concurrent_write = True
            count = min(len(data), self.chunk_size)
            self.value.extend(data[:count])
            self.active_writers -= 1
            return count

    def flush(self) -> None:
        self.flushes += 1


class WriterTests(unittest.TestCase):
    def test_serialized_writer_handles_partial_writes(self) -> None:
        sink = ChunkedSink()
        writer = dap.SerializedDAPWriter(sink)
        messages = [
            {"seq": 1, "type": "request", "command": "threads"},
            {"seq": 2, "type": "request", "command": "modules"},
        ]
        threads = [threading.Thread(target=writer.send, args=(message,)) for message in messages]
        for thread in threads:
            thread.start()
        for thread in threads:
            thread.join()
        parser = dap.DAPFrameParser()
        decoded = parser.feed(bytes(sink.value))
        parser.finish()
        self.assertCountEqual(decoded, messages)
        self.assertFalse(sink.concurrent_write)
        self.assertEqual(sink.flushes, 2)

    def test_zero_length_write_fails_closed(self) -> None:
        class ClosedSink:
            def write(self, data: bytes) -> int:
                return 0

        with self.assertRaisesRegex(dap.DAPTransportError, "made no progress"):
            dap.SerializedDAPWriter(ClosedSink()).send(
                {"seq": 1, "type": "request", "command": "threads"}
            )


class SessionTests(unittest.TestCase):
    def setUp(self) -> None:
        self.clock = MutableClock()
        self.session = dap.DAPSession(
            session_epoch=7,
            clock=self.clock,
            max_pending=2,
            max_events=2,
            max_late_messages=2,
        )

    def response(self, seq: int, request: dict[str, object], **extra: object) -> dict[str, object]:
        result: dict[str, object] = {
            "seq": seq,
            "type": "response",
            "request_seq": request["seq"],
            "command": request["command"],
            "success": True,
        }
        result.update(extra)
        return result

    def test_success_response_is_acknowledged_but_not_observed_until_postcondition(self) -> None:
        request = self.session.make_request("threads", operation="threadList")
        self.session.receive(self.response(1, request), session_epoch=7)
        self.assertEqual(self.session.result_for(request["seq"]).state, dap.RequestState.ACKNOWLEDGED)
        self.assertFalse(self.session.result_for(request["seq"]).observed)
        result = self.session.prove_postcondition(
            request["seq"], "thread identity matched", lifecycle_revision=0
        )
        self.assertEqual(result.state, dap.RequestState.OBSERVED)
        self.assertTrue(result.observed)

    def test_response_command_must_match_request(self) -> None:
        request = self.session.make_request("threads")
        with self.assertRaisesRegex(dap.DAPProtocolError, "command mismatch"):
            self.session.receive(
                self.response(1, request, command="modules"), session_epoch=7
            )

    def test_pending_and_event_stores_are_bounded(self) -> None:
        self.session.make_request("threads")
        self.session.make_request("modules")
        with self.assertRaisesRegex(dap.DAPProtocolError, "pending request limit"):
            self.session.make_request("stackTrace")
        for seq, name in enumerate(("initialized", "process", "module"), start=1):
            self.session.receive(
                {"seq": seq, "type": "event", "event": name}, session_epoch=7
            )
        self.assertEqual([envelope.message["event"] for envelope in self.session.events], ["process", "module"])
        self.assertEqual(self.session.dropped_event_count, 1)

    def test_terminal_request_records_are_pruned_to_the_configured_bound(self) -> None:
        first = self.session.make_request("threads")
        self.session.receive(self.response(1, first), session_epoch=7)
        self.session.prove_postcondition(first["seq"], "threads matched")
        second = self.session.make_request("modules")
        self.session.receive(self.response(2, second), session_epoch=7)
        self.session.prove_postcondition(second["seq"], "modules matched")

        third = self.session.make_request("evaluate")

        self.assertEqual(third["seq"], 3)
        with self.assertRaisesRegex(dap.DAPProtocolError, "unknown request"):
            self.session.result_for(first["seq"])

    def test_stop_events_own_monotonic_revisions_and_envelopes(self) -> None:
        self.session.receive(
            {"seq": 1, "type": "event", "event": "stopped"}, session_epoch=7
        )
        first = self.session.events[-1]
        self.assertEqual((first.session_epoch, first.lifecycle_revision, first.stop_revision), (7, 1, 1))
        self.session.receive(
            {"seq": 2, "type": "event", "event": "continued"}, session_epoch=7
        )
        self.session.receive(
            {"seq": 3, "type": "event", "event": "stopped"}, session_epoch=7
        )
        self.assertEqual((self.session.lifecycle_revision, self.session.stop_revision), (3, 2))

    def test_stopped_operation_must_bind_current_stop_revision(self) -> None:
        self.session.receive(
            {"seq": 1, "type": "event", "event": "stopped"}, session_epoch=7
        )
        request = self.session.make_request("stackTrace", requires_stop=True)
        self.session.receive(self.response(2, request), session_epoch=7)
        self.session.receive(
            {"seq": 3, "type": "event", "event": "continued"}, session_epoch=7
        )
        with self.assertRaisesRegex(dap.DAPProtocolError, "stop revision changed"):
            self.session.prove_postcondition(request["seq"], "frames matched")

    def test_step_postcondition_requires_a_new_stop(self) -> None:
        self.session.receive(
            {"seq": 1, "type": "event", "event": "stopped"}, session_epoch=7
        )
        request = self.session.make_request("next", requires_stop=True, requires_new_stop=True)
        self.session.receive(self.response(2, request), session_epoch=7)
        with self.assertRaisesRegex(dap.DAPProtocolError, "new stop revision"):
            self.session.prove_postcondition(request["seq"], "step completed")
        self.session.receive(
            {"seq": 3, "type": "event", "event": "continued"}, session_epoch=7
        )
        self.session.receive(
            {"seq": 4, "type": "event", "event": "stopped"}, session_epoch=7
        )
        self.assertTrue(self.session.prove_postcondition(request["seq"], "step completed").observed)

    def test_cancel_acknowledgement_wins_then_late_original_response_is_ignored(self) -> None:
        original = self.session.make_request("evaluate")
        cancel = self.session.request_cancel(original["seq"])
        self.assertEqual(self.session.result_for(original["seq"]).state, dap.RequestState.CANCELLATION_REQUESTED)
        self.session.receive(self.response(1, cancel), session_epoch=7)
        self.assertEqual(self.session.result_for(original["seq"]).state, dap.RequestState.CANCELLED)
        self.session.receive(self.response(2, original), session_epoch=7)
        self.assertEqual(self.session.result_for(original["seq"]).state, dap.RequestState.CANCELLED)
        self.assertEqual(len(self.session.late_messages), 1)

    def test_original_response_wins_cancel_race(self) -> None:
        original = self.session.make_request("evaluate")
        cancel = self.session.request_cancel(original["seq"])
        self.session.receive(self.response(1, original), session_epoch=7)
        self.session.receive(self.response(2, cancel), session_epoch=7)
        self.assertEqual(self.session.result_for(original["seq"]).state, dap.RequestState.ACKNOWLEDGED)

    def test_cancel_rejection_does_not_falsely_cancel_original(self) -> None:
        original = self.session.make_request("evaluate")
        cancel = self.session.request_cancel(original["seq"])
        self.session.receive(
            self.response(1, cancel, success=False, message="not cancellable"),
            session_epoch=7,
        )
        self.assertEqual(self.session.result_for(original["seq"]).state, dap.RequestState.PENDING)

    def test_deadline_eof_invalidation_and_prior_epoch_fail_closed(self) -> None:
        request = self.session.make_request("threads", timeout_seconds=1)
        self.clock.value += 2
        self.assertEqual(self.session.expire_deadlines(), [request["seq"]])
        self.assertEqual(self.session.result_for(request["seq"]).state, dap.RequestState.TIMED_OUT)
        self.session.receive(self.response(1, request), session_epoch=7)
        self.assertEqual(len(self.session.late_messages), 1)

        pending = self.session.make_request("modules")
        self.session.adapter_eof("exit 9")
        self.assertEqual(self.session.result_for(pending["seq"]).state, dap.RequestState.HARNESS_ERROR)
        with self.assertRaisesRegex(dap.DAPProtocolError, "invalidated"):
            self.session.receive(
                {"seq": 2, "type": "event", "event": "terminated"}, session_epoch=7
            )

        other = dap.DAPSession(session_epoch=8, clock=self.clock)
        with self.assertRaisesRegex(dap.DAPProtocolError, "older session epoch"):
            other.receive(
                {"seq": 1, "type": "event", "event": "initialized"}, session_epoch=7
            )


class LifecycleTranscriptTests(unittest.TestCase):
    def setUp(self) -> None:
        self.clock = MutableClock()
        self.session = dap.DAPSession(session_epoch=11, clock=self.clock)
        self.lifecycle = dap.DAPLifecycleStateMachine(self.session)
        self.incoming = 0

    def response(self, request: dict[str, object]) -> dict[str, object]:
        self.incoming += 1
        return {
            "seq": self.incoming,
            "type": "response",
            "request_seq": request["seq"],
            "command": request["command"],
            "success": True,
        }

    def event(self, name: str, body: dict[str, object] | None = None) -> dict[str, object]:
        self.incoming += 1
        message: dict[str, object] = {
            "seq": self.incoming,
            "type": "event",
            "event": name,
        }
        if body is not None:
            message["body"] = body
        return message

    def initialize_and_begin(self, operation: str, pid: int | None = None):
        initialize = self.lifecycle.begin_initialize({"adapterID": "lldb-dap"}, 5.0)
        self.lifecycle.accept(self.response(initialize))
        arguments: dict[str, object] = {"stopOnEntry": True}
        if pid is not None:
            arguments["pid"] = pid
        start = self.lifecycle.begin_start(operation, arguments, 5.0)
        return initialize, start

    def test_attach_waits_for_initialized_then_configuration_and_exact_later_stop(self) -> None:
        initialize, attach = self.initialize_and_begin("attach", 4242)
        self.assertEqual(initialize["command"], "initialize")
        self.assertEqual(attach["arguments"], {"pid": 4242, "stopOnEntry": True})

        self.lifecycle.accept(self.event("initialized"))
        configuration = self.lifecycle.configuration_request_if_ready(5.0)
        self.assertIsNotNone(configuration)
        self.assertEqual(configuration["command"], "configurationDone")
        self.assertIsNone(self.lifecycle.configuration_request_if_ready(5.0))

        # Responses and events may interleave in either direction. Completion
        # still requires the exact process event and a later stopped event.
        self.lifecycle.accept(self.response(configuration))
        self.lifecycle.accept(self.event("process", {
            "systemProcessId": 4242, "startMethod": "attach", "isLocalProcess": True,
        }))
        self.assertFalse(self.lifecycle.start_complete)
        self.lifecycle.accept(self.response(attach))
        self.assertFalse(self.lifecycle.start_complete)
        self.lifecycle.accept(self.event("stopped", {"reason": "entry", "threadId": 7}))
        self.assertTrue(self.lifecycle.start_complete)

        facts = self.lifecycle.facts()
        self.assertEqual(facts.operation, "attach")
        self.assertEqual(facts.process.systemProcessId, 4242)
        self.assertEqual(facts.process.startMethod, "attach")
        self.assertTrue(facts.process.isLocal)
        self.assertGreater(facts.stopped.eventSequence, facts.process.eventSequence)
        self.assertEqual(facts.sessionEpoch, 11)

    def test_start_rejects_inexact_process_identity_and_early_stop(self) -> None:
        for body, message in (
            ({"systemProcessId": 42, "startMethod": "launch", "isLocalProcess": True}, "start method"),
            ({"systemProcessId": 42, "startMethod": "attach", "isLocalProcess": False}, "local process"),
            ({"systemProcessId": 43, "startMethod": "attach", "isLocalProcess": True}, "requested PID"),
            ({"systemProcessId": 42, "startMethod": "attach", "isLocal": True}, "local process"),
        ):
            with self.subTest(body=body):
                session = dap.DAPSession(session_epoch=11, clock=self.clock)
                lifecycle = dap.DAPLifecycleStateMachine(session)
                init = lifecycle.begin_initialize({}, 5.0)
                lifecycle.accept({"seq": 1, "type": "response", "request_seq": init["seq"],
                                  "command": "initialize", "success": True})
                lifecycle.begin_start("attach", {"pid": 42, "stopOnEntry": True}, 5.0)
                lifecycle.accept({"seq": 2, "type": "event", "event": "initialized"})
                with self.assertRaisesRegex(dap.DAPProtocolError, message):
                    lifecycle.accept({"seq": 3, "type": "event", "event": "process", "body": body})

        _, attach = self.initialize_and_begin("attach", 4242)
        self.lifecycle.accept(self.event("initialized"))
        with self.assertRaisesRegex(dap.DAPProtocolError, "before exact process"):
            self.lifecycle.accept(self.event("stopped", {"reason": "entry"}))

    def _complete_attach(self) -> None:
        _, attach = self.initialize_and_begin("attach", 4242)
        self.lifecycle.accept(self.event("initialized"))
        configuration = self.lifecycle.configuration_request_if_ready(5.0)
        self.lifecycle.accept(self.event("process", {
            "systemProcessId": 4242, "startMethod": "attach", "isLocalProcess": True,
        }))
        self.lifecycle.accept(self.event("stopped", {"reason": "entry"}))
        self.lifecycle.accept(self.response(configuration))
        self.lifecycle.accept(self.response(attach))
        self.assertTrue(self.lifecycle.start_complete)

    def _complete_launch(self) -> None:
        _, launch = self.initialize_and_begin("launch")
        self.lifecycle.accept(self.event("initialized"))
        configuration = self.lifecycle.configuration_request_if_ready(5.0)
        self.lifecycle.accept(self.event("process", {
            "systemProcessId": 4242, "startMethod": "launch", "isLocalProcess": True,
        }))
        self.lifecycle.accept(self.event("stopped", {"reason": "entry"}))
        self.lifecycle.accept(self.response(configuration))
        self.lifecycle.accept(self.response(launch))
        self.assertTrue(self.lifecycle.start_complete)

    def test_disconnect_is_nonterminating_and_accepts_response_event_in_either_order(self) -> None:
        for terminated_first in (False, True):
            with self.subTest(terminated_first=terminated_first):
                self.setUp()
                self._complete_attach()
                request = self.lifecycle.begin_disconnect(5.0, terminate_debuggee=False)
                self.assertEqual(request["arguments"], {"terminateDebuggee": False})
                if terminated_first:
                    self.lifecycle.accept(self.event("terminated"))
                    self.lifecycle.accept(self.response(request))
                else:
                    self.lifecycle.accept(self.response(request))
                    self.lifecycle.accept(self.event("terminated"))
                self.assertTrue(self.lifecycle.disconnect_complete)
                self.assertIsNotNone(self.lifecycle.facts().terminated)
                self.assertIsNone(self.lifecycle.facts().exited)

    def test_launch_disconnect_terminates_debuggee_and_requires_response_and_event(self) -> None:
        self._complete_launch()
        request = self.lifecycle.begin_disconnect(5.0, terminate_debuggee=True)
        self.assertEqual(request["arguments"], {"terminateDebuggee": True})
        self.lifecycle.accept(self.event("terminated"))
        self.assertFalse(self.lifecycle.disconnect_complete)
        self.lifecycle.accept(self.response(request))
        self.assertTrue(self.lifecycle.disconnect_complete)
        self.assertEqual(self.lifecycle.facts().terminated.eventName, "terminated")

    def test_exited_is_recorded_distinctly_and_does_not_satisfy_terminated(self) -> None:
        self._complete_attach()
        request = self.lifecycle.begin_disconnect(5.0, terminate_debuggee=False)
        self.lifecycle.accept(self.event("exited", {"exitCode": 9}))
        self.lifecycle.accept(self.response(request))
        self.assertFalse(self.lifecycle.disconnect_complete)
        facts = self.lifecycle.facts()
        self.assertEqual(facts.exited.exitCode, 9)
        self.assertIsNone(facts.terminated)

    def test_initialize_is_once_per_fresh_adapter_and_duplicate_event_fails(self) -> None:
        request = self.lifecycle.begin_initialize({}, 5.0)
        with self.assertRaisesRegex(dap.DAPProtocolError, "already sent"):
            self.lifecycle.begin_initialize({}, 5.0)
        self.lifecycle.accept(self.response(request))
        self.lifecycle.begin_start("launch", {"program": "/tmp/app", "stopOnEntry": True}, 5.0)
        self.lifecycle.accept(self.event("initialized"))
        with self.assertRaisesRegex(dap.DAPProtocolError, "duplicate initialized"):
            self.lifecycle.accept(self.event("initialized"))


class DrainingTests(unittest.TestCase):
    def test_drain_is_bounded_and_honors_cancellation(self) -> None:
        source = io.BytesIO(b"abcdefghijkl")
        output = dap.BoundedOutputBuffer(5)
        result = dap.drain_stream(source, output, chunk_size=3, deadline=lambda: False)
        self.assertTrue(result.eof)
        self.assertEqual(output.value(), b"hijkl")
        self.assertEqual(output.dropped_bytes, 7)

        cancelled = threading.Event()
        cancelled.set()
        result = dap.drain_stream(
            io.BytesIO(b"unread"), dap.BoundedOutputBuffer(8), cancellation=cancelled
        )
        self.assertTrue(result.cancelled)
        self.assertFalse(result.eof)

    def test_drain_honors_monotonic_deadline_before_blocking_read(self) -> None:
        class ExplodingStream:
            def read(self, size: int) -> bytes:
                raise AssertionError("read must not be called after deadline")

        result = dap.drain_stream(
            ExplodingStream(), dap.BoundedOutputBuffer(8), deadline=lambda: True
        )
        self.assertTrue(result.timed_out)
        self.assertFalse(result.eof)


if __name__ == "__main__":
    unittest.main()
