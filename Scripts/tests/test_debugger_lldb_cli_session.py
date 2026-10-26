#!/usr/bin/env python3

from __future__ import annotations

import importlib.util
import subprocess
import sys
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
PATH = ROOT / "Scripts" / "debugger-fixture" / "lldb_cli_session.py"
SPEC = importlib.util.spec_from_file_location("lldb_cli_session", PATH)
assert SPEC and SPEC.loader
cli = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = cli
SPEC.loader.exec_module(cli)


class FakeChannel:
    def __init__(self, bodies, order=None):
        self.bodies = list(bodies)
        self.calls = []
        self.order = order if order is not None else []

    def exchange(self, payload, *, begin_marker, end_marker, timeout, max_bytes):
        self.calls.append((payload, begin_marker, end_marker, timeout, max_bytes))
        self.order.append("exchange:%d" % len(self.calls))
        body = self.bodies.pop(0)
        return begin_marker + "\n" + body + "\n" + end_marker + "\n"


class FakeLifecycle:
    def __init__(self, channel, order=None):
        self.channel = channel
        self.order = order if order is not None else channel.order
        self.open_calls = []
        self.close_calls = []
        self.authorization_calls = []
        self.begin_calls = []
        self.accept_calls = []
        self.stop_calls = []

    def open_cli_session(self, argv):
        self.open_calls.append(tuple(argv))
        return self.channel, "REGISTRATION"

    def close_cli_session(self, registration, timeout):
        self.close_calls.append((registration, timeout))
        return {"role": "adapter", "registration": registration, "complete": True}

    def authorize_launch(self, executable, arguments, cwd, environment):
        self.authorization_calls.append(
            (executable, tuple(arguments), cwd, dict(environment)))
        return {"authorized": True, "nonce": "N", "launch": {
            "executable": executable, "arguments": list(arguments),
            "workingDirectory": cwd, "environment": dict(environment)}}

    def accept_launch(self, pid, authorization, timeout):
        self.order.append("accept")
        self.accept_calls.append((pid, authorization, timeout))

    def begin_launch_readiness(self, pid, authorization, timeout):
        self.order.append("begin")
        self.begin_calls.append((pid, authorization, timeout))

    def accept_launch_stop(self, pid, authorization, timeout):
        self.order.append("stop")
        self.stop_calls.append((pid, authorization, timeout))
        return {"source": "fake-bsd-status", "pid": pid, "status": 4}


class IncompleteLifecycle(FakeLifecycle):
    def close_cli_session(self, registration, timeout):
        self.close_calls.append((registration, timeout))
        return {"role": "adapter", "registration": registration, "complete": False}


class PersistentSessionTests(unittest.TestCase):
    def session(self, bodies):
        order = []
        channel = FakeChannel(bodies, order)
        lifecycle = FakeLifecycle(channel, order)
        session = cli.PersistentLLDBCLISession(
            Path("/SelectedXcode/usr/bin/lldb"), lifecycle,
            session_token="Session_01234567", timeout=2.5,
        )
        return session, channel, lifecycle

    def test_one_registered_process_serves_multiple_correlated_commands_and_closes_once(self):
        session, channel, lifecycle = self.session([
            "Process 431 stopped\nstop reason = breakpoint 1.1",
            "Process 431 stopped\nframe #0: 0x1000",
        ])
        first = session.execute(cli.CLICommandRequest(
            "refresh", "refresh-1", ("process status",), expectedPID=431,
        ))
        second = session.execute(cli.CLICommandRequest(
            "frameList", "frames-1", ("thread backtrace",), expectedPID=431,
        ))
        receipt = session.close()
        self.assertEqual((first.observation, second.observation), ("observed", "observed"))
        self.assertEqual((first.targetPID, second.targetPID), (431, 431))
        self.assertEqual(len(lifecycle.open_calls), 1)
        self.assertEqual(lifecycle.open_calls[0],
                         ("/SelectedXcode/usr/bin/lldb", "--no-lldbinit"))
        self.assertEqual(len(lifecycle.close_calls), 1)
        self.assertTrue(receipt["complete"])
        self.assertEqual(session.close(), receipt)
        self.assertEqual(len(lifecycle.close_calls), 1)
        self.assertNotEqual(channel.calls[0][1], channel.calls[1][1])
        self.assertIn("process status", channel.calls[0][0])

    def test_semantic_operation_is_distinct_from_wire_command_and_evidence_is_bounded(self):
        session, channel, _ = self.session(["Process 19 stopped\n" + "x" * 9000])
        result = session.execute(cli.CLICommandRequest(
            "registerRead", "register-read-1", ("register read x0",), expectedPID=19,
        ))
        self.assertEqual(result.semanticOperation, "registerRead")
        self.assertEqual(result.wireCommands, ("register read x0", "process status"))
        self.assertEqual(result.observation, "observed")
        self.assertLessEqual(len(result.diagnosticPreview.encode("utf-8")),
                             cli.MAX_DIAGNOSTIC_BYTES)
        self.assertTrue(result.diagnosticTruncated)
        self.assertEqual(len(result.transcriptSHA256), 64)
        self.assertIn("register read x0", channel.calls[0][0])
        self.assertNotIn("semanticOperation", channel.calls[0][0])

    def test_launch_pid_is_a_protocol_fact_not_an_expected_value_copied_into_output(self):
        session, channel, lifecycle = self.session([
            "Process 777 launched: '/tmp/Main' (arm64)\nProcess 777 stopped\nstop reason = signal SIGSTOP",
            "Process 777 resume requested",
            "Process 777 stopped\nstop reason = signal SIGSTOP",
        ])
        result = session.execute_operation("configuredLaunch", "launch-1", {
            "executable": "/tmp/Main", "arguments": ["--nonce", "N"],
            "workingDirectory": "/tmp", "environment": {},
        })
        self.assertEqual(result.observation, "observed")
        self.assertEqual(result.targetPID, 777)
        self.assertEqual(result.targetDisposition, "stopped")
        self.assertEqual(result.protocolFact["targetPID"], 777)
        self.assertEqual(result.protocolFact["source"], "lldb-cli-transcript")
        self.assertEqual(len(channel.calls), 3)
        self.assertEqual(lifecycle.authorization_calls,
                         [("/tmp/Main", ("--nonce", "N"), "/tmp", {})])
        self.assertEqual(lifecycle.accept_calls[0][0], 777)
        self.assertEqual(lifecycle.begin_calls,
                         [(777, lifecycle.accept_calls[0][1], 2.5)])
        self.assertEqual(lifecycle.order,
                         ["exchange:1", "begin", "exchange:2", "accept",
                          "stop", "exchange:3"])
        self.assertIn("process launch -s", channel.calls[0][0])
        self.assertIn("_ms_process.Continue()", channel.calls[1][0])
        self.assertIn("process status", channel.calls[2][0])
        self.assertEqual(result.protocolFact["stoppedPostcondition"]["status"], 4)

    def test_expected_pid_mismatch_and_ambiguous_pid_fail_closed(self):
        session, _, _ = self.session([
            "Process 42 stopped",
            "Process 42 stopped\nProcess 43 stopped",
        ])
        mismatch = session.execute(cli.CLICommandRequest(
            "refresh", "R1", ("process status",), expectedPID=41,
        ))
        ambiguous = session.execute(cli.CLICommandRequest(
            "refresh", "R2", ("process status",), expectedPID=42,
        ))
        self.assertEqual(mismatch.observation, "identityMismatch")
        self.assertEqual(ambiguous.observation, "identityMismatch")
        self.assertIsNone(ambiguous.targetPID)

    def test_stopped_operation_requires_stopped_postcondition(self):
        session, _, _ = self.session(["Process 42 resuming"])
        result = session.execute(cli.CLICommandRequest(
            "registerRead", "R", ("register read",), expectedPID=42,
        ))
        self.assertEqual(result.observation, "protocolError")
        self.assertEqual(result.targetDisposition, "targetDispositionUnknown")

    def test_structural_unsupported_is_typed_and_does_not_write_to_session(self):
        session, channel, _ = self.session([])
        result = session.execute_operation("cancelInFlight", "cancel-1")
        self.assertEqual(result.observation, "unsupported")
        self.assertEqual(result.semanticOperation, "cancelInFlight")
        self.assertEqual(result.targetDisposition, "targetDispositionUnknown")
        self.assertIn("correlated cancellation", result.negativeEvidence["reason"])
        self.assertEqual(channel.calls, [])

    def test_every_frozen_operation_has_an_explicit_cli_classification(self):
        supported = set(cli.SUPPORTED_OPERATIONS)
        unsupported = set(cli.STRUCTURALLY_UNSUPPORTED)
        self.assertFalse(supported & unsupported)
        self.assertEqual(supported | unsupported, set(cli.OPERATION_ORDER))
        for operation in cli.OPERATION_ORDER:
            classification = cli.classify_operation(operation)
            self.assertIn(classification, {"supported", "structurallyUnsupported"})

    def test_attach_and_nonterminating_detach_share_one_session(self):
        session, channel, lifecycle = self.session([
            "Process 888 stopped\nstop reason = signal SIGSTOP",
            "Process 888 detached",
        ])
        checkpoints = []
        attached, detached = session.attach_and_detach(
            pid=888, attach_request_id="attach-1", detach_request_id="detach-1",
            post_detach_probe=lambda pid: checkpoints.append(pid) or {
                "sameIdentity": True, "alive": True, "controllable": True,
                "checkpointSequence": 9,
            },
        )
        self.assertEqual(attached.observation, "observed")
        self.assertEqual(detached.observation, "observed")
        self.assertEqual(detached.targetDisposition, "detached")
        self.assertEqual(checkpoints, [888])
        self.assertEqual(len(lifecycle.open_calls), 1)
        self.assertEqual(len(channel.calls), 2)
        self.assertIn("process attach --pid 888", channel.calls[0][0])
        self.assertIn("process detach", channel.calls[1][0])

    def test_attach_admission_callback_runs_before_detach(self):
        session, channel, _ = self.session([
            "Process 888 stopped\nstop reason = signal SIGSTOP",
            "Process 888 detached",
        ])
        order = []

        attached, detached = session.attach_and_detach(
            pid=888, attach_request_id="attach-1", detach_request_id="detach-1",
            on_attached=lambda evidence: order.append(
                ("admitted", evidence.targetPID, len(channel.calls))),
            post_detach_probe=lambda pid: order.append(
                ("detached", pid, len(channel.calls))) or {
                    "sameIdentity": True, "alive": True, "controllable": True,
                    "checkpointSequence": 9,
                },
        )

        self.assertEqual(attached.observation, "observed")
        self.assertEqual(detached.observation, "observed")
        self.assertEqual(order, [("admitted", 888, 1), ("detached", 888, 2)])

    def test_detach_acknowledgement_without_live_control_probe_is_not_observed(self):
        session, _, _ = self.session([
            "Process 99 stopped",
            "Process 99 detached",
        ])
        _, detached = session.attach_and_detach(
            pid=99, attach_request_id="A", detach_request_id="D",
            post_detach_probe=lambda _: {
                "sameIdentity": True, "alive": True, "controllable": False,
                "checkpointSequence": 0,
            },
        )
        self.assertEqual(detached.observation, "identityMismatch")
        self.assertEqual(detached.targetDisposition, "targetDispositionUnknown")

    def test_context_manager_closes_after_protocol_error(self):
        session, _, lifecycle = self.session(["Process 9 running"])
        with session:
            result = session.execute(cli.CLICommandRequest(
                "refresh", "R", ("process status",), expectedPID=9,
            ))
            self.assertEqual(result.observation, "protocolError")
        self.assertEqual(len(lifecycle.close_calls), 1)

    def test_incomplete_cleanup_receipt_is_preserved_without_a_second_close_attempt(self):
        channel = FakeChannel([])
        lifecycle = IncompleteLifecycle(channel)
        session = cli.PersistentLLDBCLISession(
            Path("/SelectedXcode/usr/bin/lldb"), lifecycle,
            session_token="Session_01234567",
        )
        with self.assertRaisesRegex(RuntimeError, "incomplete cleanup"):
            session.close()
        with self.assertRaisesRegex(RuntimeError, "incomplete cleanup"):
            session.close()
        self.assertEqual(len(lifecycle.close_calls), 1)

    def test_expected_exit_reuses_observed_terminal_evidence_without_second_command(self):
        session, channel, _ = self.session([
            "Process 777 exited with status = 9",
        ])
        terminated = session.execute_operation("terminate", "terminate-1")
        expected = session.execute_operation("expectedExit", "expected-exit-1")
        self.assertEqual(terminated.observation, "observed")
        self.assertEqual(expected.observation, "observed")
        self.assertEqual(expected.targetPID, 777)
        self.assertEqual(expected.targetDisposition, "exited")
        self.assertEqual(expected.wireCommands, ())
        self.assertEqual(len(channel.calls), 1)
        self.assertEqual(expected.protocolFact["source"], "lldb-cli-transcript")
        self.assertEqual(expected.protocolFact["evidenceMode"], "retained-terminal")
        self.assertEqual(expected.protocolFact["originatingRequestID"], "terminate-1")
        self.assertGreater(expected.protocolFact["commandSequence"],
                           terminated.protocolFact["commandSequence"])
        self.assertEqual(expected.protocolFact["originatingCommandSequence"],
                         terminated.protocolFact["commandSequence"])
        self.assertEqual(expected.protocolFact["transcriptSHA256"],
                         terminated.transcriptSHA256)

    def test_missing_required_operation_argument_returns_typed_negative_evidence(self):
        session, channel, _ = self.session([])
        result = session.execute_operation(
            "configuredLaunch", "launch-without-executable", {})
        self.assertEqual(result.observation, "notAttempted")
        self.assertEqual(result.negativeEvidence["classification"], "notAttempted")
        self.assertEqual(result.negativeEvidence["stage"], "configuredLaunch")
        self.assertIn("executable is required", result.negativeEvidence["reason"])
        self.assertEqual(channel.calls, [])

    def test_configured_launch_applies_arguments_environment_and_working_directory(self):
        commands, require_stopped, state = cli._wire_commands(
            "configuredLaunch", {
                "executable": "/tmp/Main Fixture",
                "arguments": ["--control-dir", "/tmp/control dir", "--nonce", "N"],
                "workingDirectory": "/tmp/work dir",
                "environment": {"MACSCOPE_FIXTURE": "ready value"},
            })

        self.assertEqual(commands, (
            'target create "/tmp/Main Fixture"',
            'settings clear target.run-args',
            'settings set -- target.run-args "--control-dir" "/tmp/control dir" "--nonce" "N"',
            'settings clear target.env-vars',
            'settings set target.env-vars MACSCOPE_FIXTURE="ready value"',
            'platform settings -w "/tmp/work dir"',
            "process launch -s",
        ))
        self.assertTrue(require_stopped)
        self.assertEqual(state, "stopped")

    def test_lldb_command_values_escape_expression_substitution(self):
        commands, _, _ = cli._wire_commands("configuredLaunch", {
            "executable": "/tmp/`target`",
            "arguments": ["`1+1`"],
            "workingDirectory": "/tmp/`work`",
            "environment": {"VALUE": "`2+2`"},
        })

        self.assertEqual(commands[0], 'target create "/tmp/\\`target\\`"')
        self.assertEqual(
            commands[2], 'settings set -- target.run-args "\\`1+1\\`"')
        self.assertEqual(
            commands[4], 'settings set target.env-vars VALUE="\\`2+2\\`"')
        self.assertEqual(commands[5], 'platform settings -w "/tmp/\\`work\\`"')

    def test_configured_launch_denial_precedes_every_cli_exchange(self):
        session, channel, lifecycle = self.session([])
        lifecycle.authorize_launch = lambda *args: {
            "authorized": False, "reason": "frozen launch mismatch"}
        result = session.execute_operation("configuredLaunch", "launch-denied", {
            "executable": "/tmp/Main", "arguments": [],
            "workingDirectory": "/tmp", "environment": {},
        })
        self.assertEqual(result.observation, "notAttempted")
        self.assertEqual(channel.calls, [])

    def test_direct_configured_launch_execution_cannot_bypass_authority(self):
        session, _, _ = self.session([])
        with self.assertRaisesRegex(ValueError, "run-owned authorization"):
            session.execute(cli.CLICommandRequest(
                "configuredLaunch", "bypass",
                ('target create "/tmp/Main"', "process launch -s")))

    def test_configured_launch_rejects_command_control_characters(self):
        session, channel, _ = self.session([])
        result = session.execute_operation("configuredLaunch", "injected", {
            "executable": "/tmp/Main\nprocess kill", "arguments": [],
            "workingDirectory": "/tmp", "environment": {},
        })
        self.assertEqual(result.observation, "notAttempted")
        self.assertEqual(channel.calls, [])

    def test_readiness_rejection_aborts_unpublished_cli_inferior(self):
        session, channel, lifecycle = self.session([
            "Process 777 launched: '/tmp/Main' (arm64)\nProcess 777 stopped",
            "Process 777 stopped\nstop reason = breakpoint 1.1",
            "Process 777 exited with status = 9",
        ])
        lifecycle.accept_launch = lambda *args: (_ for _ in ()).throw(
            RuntimeError("ready mismatch"))

        result = session.execute_operation("configuredLaunch", "launch-1", {
            "executable": "/tmp/Main", "arguments": [],
            "workingDirectory": "/tmp", "environment": {},
        })

        self.assertEqual(result.observation, "identityMismatch")
        self.assertEqual(len(channel.calls), 3)
        self.assertIn("process kill", channel.calls[-1][0])
        self.assertIn("lldb.debugger.SetAsync(False)", channel.calls[-1][0])
        self.assertIn("abort=observed", result.negativeEvidence["reason"])


class PipeCLIChannelTests(unittest.TestCase):
    @staticmethod
    def cleanup(process):
        process.terminate()
        process.wait(timeout=1.0)
        for stream in (process.stdin, process.stdout, process.stderr):
            if stream is not None:
                stream.close()

    def test_real_pipe_process_exchanges_one_bounded_correlated_transcript(self):
        process = subprocess.Popen(
            (sys.executable, "-u", "-c",
             "import sys\nfor line in sys.stdin:\n sys.stdout.write(line); sys.stdout.flush()"),
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            start_new_session=True, close_fds=True,
        )
        try:
            channel = cli.PipeCLIChannel(process.stdin, process.stdout, process.stderr)
            raw = channel.exchange(
                "BEGIN\nprocess status\nEND\n",
                begin_marker="BEGIN", end_marker="END", timeout=1.0,
                max_bytes=1024,
            )
            self.assertEqual(raw, "BEGIN\nprocess status\nEND\n")
        finally:
            self.cleanup(process)

    def test_pipe_exchange_ignores_marker_inside_echoed_command(self):
        process = subprocess.Popen(
            (sys.executable, "-u", "-c",
             "import sys\nfor line in sys.stdin:\n sys.stdout.write(line); sys.stdout.flush()"),
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            start_new_session=True, close_fds=True,
        )
        try:
            channel = cli.PipeCLIChannel(process.stdin, process.stdout, process.stderr)
            raw = channel.exchange(
                "script print('BEGIN')\nBEGIN\nscript print('END')\nEND\n",
                begin_marker="BEGIN", end_marker="END", timeout=1.0,
                max_bytes=1024,
            )
            self.assertEqual(raw, (
                "script print('BEGIN')\nBEGIN\nscript print('END')\nEND\n"))
        finally:
            self.cleanup(process)

    def test_pipe_exchange_times_out_without_an_end_marker(self):
        process = subprocess.Popen(
            (sys.executable, "-u", "-c",
             "import sys, time\nsys.stdin.readline()\ntime.sleep(10)"),
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            start_new_session=True, close_fds=True,
        )
        try:
            channel = cli.PipeCLIChannel(process.stdin, process.stdout, process.stderr)
            with self.assertRaisesRegex(TimeoutError, "deadline"):
                channel.exchange(
                    "BEGIN\n", begin_marker="BEGIN", end_marker="END",
                    timeout=0.05, max_bytes=1024,
                )
        finally:
            self.cleanup(process)

    def test_pipe_exchange_rejects_output_beyond_the_byte_bound(self):
        process = subprocess.Popen(
            (sys.executable, "-u", "-c",
             "import sys\nsys.stdin.readline()\nsys.stdout.write('x' * 2048); sys.stdout.flush()"),
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            start_new_session=True, close_fds=True,
        )
        try:
            channel = cli.PipeCLIChannel(process.stdin, process.stdout, process.stderr)
            with self.assertRaisesRegex(ValueError, "byte bound"):
                channel.exchange(
                    "BEGIN\n", begin_marker="BEGIN", end_marker="END",
                    timeout=1.0, max_bytes=128,
                )
        finally:
            self.cleanup(process)


if __name__ == "__main__":
    unittest.main()
