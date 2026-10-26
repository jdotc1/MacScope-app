#!/usr/bin/env python3

from __future__ import annotations

import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
FIXTURE_TOOL = REPOSITORY_ROOT / "Scripts" / "debugger-fixture" / "fixture_tool.py"


def load_fixture_tool():
    specification = importlib.util.spec_from_file_location("fixture_tool_runtime", FIXTURE_TOOL)
    assert specification is not None and specification.loader is not None
    module = importlib.util.module_from_spec(specification)
    sys.modules[specification.name] = module
    specification.loader.exec_module(module)
    return module


def command(sequence, nonce="run-123", operation="checkpoint"):
    return json.dumps(
        {
            "schema": 1,
            "sequence": sequence,
            "nonce": nonce,
            "operation": operation,
        },
        separators=(",", ":"),
        sort_keys=True,
    )


class DebuggerFixtureRuntimeTests(unittest.TestCase):
    def setUp(self):
        self.tool = load_fixture_tool()
        self.protocol = self.tool.RuntimeProtocol(nonce="run-123", role="helper", pid=4242)

    def test_readiness_and_commands_emit_monotonic_identity_rich_events(self):
        ready = self.protocol.ready()
        self.assertIsNotNone(ready, "runtime must emit a readiness event")
        checkpoint = self.protocol.accept(command(1))
        loaded = self.protocol.accept(command(2, operation="load"))
        framework_checkpoint = self.protocol.accept(command(3))
        unloaded = self.protocol.accept(command(4, operation="unload"))

        self.assertEqual(
            [event["sequence"] for event in [ready, checkpoint, loaded, framework_checkpoint, unloaded]],
            [1, 2, 3, 4, 5],
        )
        self.assertTrue(all(event["nonce"] == "run-123" for event in [ready, checkpoint, loaded]))
        self.assertTrue(all(event["role"] == "helper" for event in [ready, checkpoint, loaded]))
        self.assertEqual(framework_checkpoint["counters"]["checkpoint"], 2)
        self.assertEqual(loaded["counters"]["load"], 1)
        self.assertEqual(unloaded["counters"]["unload"], 1)
        self.assertFalse(unloaded["frameworkLoaded"])

    def test_invalid_commands_fail_without_advancing_sequence(self):
        invalid_lines = [
            "not-json",
            command(1, nonce="wrong"),
            json.dumps({"schema": 1, "sequence": 1, "nonce": "run-123"}),
            "{" + ("x" * 4097) + "}",
        ]
        for line in invalid_lines:
            with self.assertRaises(self.tool.FixtureError):
                self.protocol.accept(line)
        accepted = self.protocol.accept(command(1))
        self.assertEqual(accepted["commandSequence"], 1)
        with self.assertRaises(self.tool.FixtureError):
            self.protocol.accept(command(1))
        with self.assertRaises(self.tool.FixtureError):
            self.protocol.accept(command(3))

    def test_detach_survives_and_eof_exits_deterministically(self):
        self.protocol.ready()
        disconnected = self.protocol.debugger_disconnected()
        self.assertFalse(disconnected["exiting"])
        checkpoint = self.protocol.accept(command(1))
        self.assertEqual(checkpoint["result"], "ok")
        eof = self.protocol.command_eof()
        self.assertTrue(eof["exiting"])
        self.assertEqual(eof["operation"], "commandEOF")
        with self.assertRaises(self.tool.FixtureError):
            self.protocol.accept(command(2))

    def test_control_paths_require_private_permissions_owner_and_fresh_root(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory) / "control"
            root.mkdir(mode=0o700)
            channel = root / "helper.commands"
            os.mkfifo(channel, mode=0o600)
            started_after_ns = root.stat().st_mtime_ns - 1
            self.tool.validate_control_root(
                root,
                expected_uid=os.getuid(),
                started_after_ns=started_after_ns,
            )
            self.tool.validate_command_channel(channel, expected_uid=os.getuid())

            regular = root / "regular.commands"
            regular.touch(mode=0o600)
            with self.assertRaises(self.tool.FixtureError):
                self.tool.validate_command_channel(regular, expected_uid=os.getuid())

            root.chmod(0o755)
            with self.assertRaises(self.tool.FixtureError):
                self.tool.validate_control_root(root, expected_uid=os.getuid(), started_after_ns=0)
            root.chmod(0o700)
            channel.chmod(0o644)
            with self.assertRaises(self.tool.FixtureError):
                self.tool.validate_command_channel(channel, expected_uid=os.getuid())
            with self.assertRaises(self.tool.FixtureError):
                self.tool.validate_control_root(root, expected_uid=os.getuid() + 1, started_after_ns=0)
            with self.assertRaises(self.tool.FixtureError):
                self.tool.validate_control_root(
                    root,
                    expected_uid=os.getuid(),
                    started_after_ns=root.stat().st_mtime_ns + 1,
                )


class CompiledFixtureRuntimeTests(unittest.TestCase):
    """Serialized tests for the C runtime that the debugger actually executes."""

    @classmethod
    def setUpClass(cls):
        cls._temporary = tempfile.TemporaryDirectory()
        cls.root = Path(cls._temporary.name)
        source_root = REPOSITORY_ROOT / "Scripts" / "debugger-fixture" / "Sources"
        contents = cls.root / "Fixture.app" / "Contents"
        cls.helper = contents / "Helpers" / "MacScopeDebuggerHelper"
        cls.framework = (
            contents
            / "Frameworks"
            / "MacScopeDebuggerFixtureRuntime.framework"
            / "MacScopeDebuggerFixtureRuntime"
        )
        cls.helper.parent.mkdir(parents=True)
        cls.framework.parent.mkdir(parents=True)
        commands = [
            [
                "/usr/bin/xcrun",
                "--sdk",
                "macosx",
                "clang",
                "-g",
                "-O0",
                "-fno-inline",
                str(source_root / "helper.c"),
                str(source_root / "fixture_runtime.c"),
                "-o",
                str(cls.helper),
            ],
            [
                "/usr/bin/xcrun",
                "--sdk",
                "macosx",
                "clang",
                "-dynamiclib",
                "-g",
                "-O0",
                "-fno-inline",
                str(source_root / "framework.c"),
                "-o",
                str(cls.framework),
            ],
        ]
        for build_command in commands:
            result = subprocess.run(build_command, capture_output=True, text=True, check=False)
            if result.returncode != 0:
                raise AssertionError("C runtime test build failed: %s" % (result.stderr or result.stdout))

    @classmethod
    def tearDownClass(cls):
        cls._temporary.cleanup()

    def _wait_for(self, predicate, description, timeout=3.0):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            value = predicate()
            if value:
                return value
            time.sleep(0.01)
        self.fail("timed out waiting for %s" % description)

    def _launch(self, *, stale=False, extra_arguments=()):
        started_after_ns = time.time_ns()
        control = self.root / ("control-%d" % time.time_ns())
        control.mkdir(mode=0o700)
        threshold = control.stat().st_mtime_ns + 1 if stale else started_after_ns
        process = subprocess.Popen(
            [
                str(self.helper),
                "--control-dir",
                str(control),
                "--nonce",
                "run-123",
                "--started-after-ns",
                str(threshold),
                *extra_arguments,
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            start_new_session=True,
        )
        return process, control

    def _connected_runtime(self):
        process, control = self._launch()
        fifo = control / "helper.commands"
        self._wait_for(fifo.exists, "command FIFO")
        writer = os.fdopen(os.open(fifo, os.O_WRONLY), "w", buffering=1)
        events = control / "helper.events.jsonl"

        def ready_event():
            if not events.exists():
                return None
            lines = events.read_text(encoding="utf-8").splitlines()
            return json.loads(lines[0]) if lines else None

        ready = self._wait_for(ready_event, "readiness event")
        self.assertEqual(ready["operation"], "ready")
        return process, control, writer

    def _events(self, control):
        path = control / "helper.events.jsonl"
        if not path.exists():
            return []
        return [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines()]

    def _cleanup(self, process, writer=None):
        if writer is not None and not writer.closed:
            writer.close()
        try:
            process.wait(timeout=2)
        except subprocess.TimeoutExpired:
            process.terminate()
            process.wait(timeout=2)
        if process.stdout is not None:
            process.stdout.close()
        if process.stderr is not None:
            process.stderr.close()

    def test_actual_runtime_loads_checkpoints_unloads_and_exits(self):
        process, control, writer = self._connected_runtime()
        try:
            for sequence, operation in enumerate(
                ("load", "checkpoint", "unload", "exit"), start=1
            ):
                writer.write(command(sequence, operation=operation) + "\n")
            self.assertEqual(process.wait(timeout=3), 0)
            operations = [event["operation"] for event in self._events(control)]
            self.assertEqual(operations, ["ready", "load", "checkpoint", "unload", "exit"])
        finally:
            self._cleanup(process, writer)

    def test_actual_runtime_rejects_unknown_fields_and_bounds_oversized_lines(self):
        for payload in (
            '{"nonce":"run-123","operation":"checkpoint","schema":1,"sequence":1,"extra":true}\n',
            "{" + ("x" * 10000) + "}\n",
        ):
            with self.subTest(payload_length=len(payload)):
                process, control, writer = self._connected_runtime()
                try:
                    writer.write(payload)
                    self.assertEqual(process.wait(timeout=3), 67)
                    self.assertEqual(self._events(control)[-1]["operation"], "protocolError")
                finally:
                    self._cleanup(process, writer)

    def test_actual_runtime_rejects_stale_root_before_creating_channels(self):
        process, control = self._launch(stale=True)
        try:
            self.assertEqual(process.wait(timeout=3), 64)
            self.assertEqual(list(control.iterdir()), [])
        finally:
            self._cleanup(process)

    def test_actual_runtime_eof_is_graceful_and_partial_channel_failure_cleans_up(self):
        process, control, writer = self._connected_runtime()
        writer.close()
        try:
            self.assertEqual(process.wait(timeout=3), 0)
            self.assertEqual(self._events(control)[-1]["operation"], "commandEOF")
        finally:
            self._cleanup(process)

        started_after_ns = time.time_ns()
        blocked = self.root / ("blocked-%d" % started_after_ns)
        blocked.mkdir(mode=0o700)
        os.mkfifo(blocked / "helper.commands", mode=0o600)
        failed = subprocess.Popen(
            [
                str(self.helper),
                "--control-dir",
                str(blocked),
                "--nonce",
                "run-123",
                "--started-after-ns",
                str(started_after_ns),
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            start_new_session=True,
        )
        try:
            self.assertEqual(failed.wait(timeout=3), 65)
            self.assertFalse((blocked / "helper.events.jsonl").exists())
        finally:
            self._cleanup(failed)


if __name__ == "__main__":
    unittest.main()
