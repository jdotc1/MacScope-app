#!/usr/bin/env python3

from __future__ import annotations

import importlib.util
import hashlib
import json
import os
import subprocess
import sys
import tempfile
import threading
import types
import unittest
from contextlib import contextmanager
from dataclasses import replace
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "Scripts" / "debugger-fixture" / "ws18_runtime_bridge.py"
spec = importlib.util.spec_from_file_location("ws18_runtime_bridge", SOURCE)
assert spec and spec.loader
bridge = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = bridge
spec.loader.exec_module(bridge)


class FakeInspector:
    def __init__(self): self.snapshots = {}
    def capture(self, pid): return self.snapshots.get(pid, bridge.supervision.ProcessSnapshot.gone())


def identity(pid, path, role, nonce="N", signer=bridge.APPROVED_FIXTURE_SIGNER):
    stat = os.stat(path)
    executable_identity = "sha256:" + hashlib.sha256(Path(path).read_bytes()).hexdigest()
    return bridge.darwin.DarwinImmutableProcessIdentity(pid, 1, 2, os.path.realpath(path),
        stat.st_dev, stat.st_ino, 501, 501, 0x0100000C, 0,
        "12345678-1234-1234-1234-123456789ABC", signer, nonce, role,
        executable_identity)


class SelectedClaimTests(unittest.TestCase):
    def test_registration_retries_only_bounded_unstable_snapshots(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "adapter"
            path.write_bytes(b"adapter")
            exact = identity(41, path, bridge.supervision.ProcessRole.ADAPTER)
            snapshots = [
                bridge.supervision.ProcessSnapshot(
                    bridge.supervision.InspectionState.UNSTABLE,
                    detail="process changed during A-B-A capture"),
                bridge.supervision.ProcessSnapshot(
                    bridge.supervision.InspectionState.EXACT, exact,
                    bridge.supervision.ProcessTopology(1, 41, 41)),
                bridge.supervision.ProcessSnapshot(
                    bridge.supervision.InspectionState.EXACT, exact,
                    bridge.supervision.ProcessTopology(1, 41, 41)),
            ]
            class Inspector:
                calls = 0
                def capture(self, pid):
                    self.calls += 1
                    return snapshots.pop(0)
            inspector = Inspector()
            context = object.__new__(bridge._Context)
            context.owner = "test"
            context.claims = bridge.darwin.SelectedProcessClaims()
            context.inspector = inspector
            context.registry = bridge.supervision.ProcessRegistry("test", inspector)
            context.approved_fixture_signer = bridge.APPROVED_FIXTURE_SIGNER
            context.closed = False

            registration = context.register(
                41, str(path), "N", bridge.supervision.ProcessRole.ADAPTER)

            self.assertEqual(registration.identity, exact)
            self.assertEqual(inspector.calls, 3)

    def test_registration_does_not_retry_uninspectable_snapshot(self):
        context = object.__new__(bridge._Context)
        context.owner = "test"
        context.claims = bridge.darwin.SelectedProcessClaims()
        context.inspector = types.SimpleNamespace(capture=lambda pid:
            bridge.supervision.ProcessSnapshot(
                bridge.supervision.InspectionState.UNINSPECTABLE,
                detail="inspection denied"))
        context.registry = types.SimpleNamespace()
        context.approved_fixture_signer = bridge.APPROVED_FIXTURE_SIGNER
        context.closed = False

        with self.assertRaisesRegex(
                bridge.RuntimeBridgeError, '"state":"uninspectable"'):
            context.register(
                41, "/tmp/adapter", "N", bridge.supervision.ProcessRole.ADAPTER)

    def test_explicit_pid_path_nonce_only_and_fixture_signer_required(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "helper"; path.write_bytes(b"fixture")
            inspector = FakeInspector()
            context = object.__new__(bridge._Context)
            context.owner = "test"; context.claims = bridge.darwin.SelectedProcessClaims()
            context.inspector = inspector
            context.registry = bridge.supervision.ProcessRegistry("test", inspector)
            context.approved_fixture_signer = bridge.APPROVED_FIXTURE_SIGNER
            context.closed = False
            good = identity(42, path, bridge.supervision.ProcessRole.ATTACHED_HELPER)
            inspector.snapshots[42] = bridge.supervision.ProcessSnapshot(
                bridge.supervision.InspectionState.EXACT, good,
                bridge.supervision.ProcessTopology(1, 42, 42))
            registration = context.register(42, str(path), "N",
                bridge.supervision.ProcessRole.ATTACHED_HELPER,
                good.executable_identity)
            self.assertEqual(registration.identity, good)

    def test_wrong_fixture_signer_is_rejected_before_registry_acceptance(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "helper"; path.write_bytes(b"fixture")
            inspector = FakeInspector()
            context = object.__new__(bridge._Context)
            context.owner = "test"; context.claims = bridge.darwin.SelectedProcessClaims()
            context.inspector = inspector
            context.registry = bridge.supervision.ProcessRegistry("test", inspector)
            context.approved_fixture_signer = bridge.APPROVED_FIXTURE_SIGNER
            context.closed = False
            bad = identity(43, path, bridge.supervision.ProcessRole.ATTACHED_HELPER,
                           signer="unsigned")
            inspector.snapshots[43] = bridge.supervision.ProcessSnapshot(
                bridge.supervision.InspectionState.EXACT, bad,
                bridge.supervision.ProcessTopology(1, 43, 43))
            with self.assertRaisesRegex(bridge.RuntimeBridgeError, "approved signing"):
                context.register(43, str(path), "N",
                    bridge.supervision.ProcessRole.ATTACHED_HELPER,
                    bad.executable_identity)
            self.assertEqual(context.registry.registrations, ())


class PIDParsingTests(unittest.TestCase):
    def test_requires_one_explicit_lldb_process_pid(self):
        self.assertEqual(bridge._explicit_lldb_pid("Process 42 stopped"), 42)
        self.assertIsNone(bridge._explicit_lldb_pid("no process"))
        self.assertIsNone(bridge._explicit_lldb_pid("Process 42\nProcess 43"))


class LifecycleFailureTests(unittest.TestCase):
    def test_signal_deferral_records_then_delivers_to_previous_handler(self):
        installed = {}
        delivered = []

        def previous(signum, frame):
            delivered.append((signum, frame))

        def install(signum, handler):
            old = installed.get(signum, previous)
            installed[signum] = handler
            return old

        with mock.patch.object(bridge.signal, "signal", side_effect=install), \
                mock.patch.object(bridge.signal, "pthread_sigmask") as mask:
            with bridge._defer_termination_signals():
                installed[bridge.signal.SIGTERM](bridge.signal.SIGTERM, "frame")
                self.assertEqual(delivered, [])

        self.assertEqual(delivered, [(bridge.signal.SIGTERM, "frame")])
        mask.assert_not_called()

    def test_signal_deferral_does_not_block_signals_in_spawned_child(self):
        program = (
            "import json,signal; "
            "print(json.dumps(sorted(int(value) for value in "
            "signal.pthread_sigmask(signal.SIG_BLOCK, set()))))"
        )

        with bridge._defer_termination_signals():
            output = subprocess.check_output(
                [sys.executable, "-c", program], text=True,
            )

        child_mask = json.loads(output)
        self.assertNotIn(int(bridge.signal.SIGINT), child_mask)
        self.assertNotIn(int(bridge.signal.SIGTERM), child_mask)

    def test_adapter_spawn_defers_termination_until_handle_and_registration_are_owned(self):
        active = False
        process = types.SimpleNamespace(pid=42)
        registration = types.SimpleNamespace(process_key="adapter-key")
        context = object.__new__(bridge._Context)
        context.owner = "dap-test"
        context.process_factory = lambda *args, **kwargs: (
            self.assertTrue(active) or process)
        context.register = lambda *args, **kwargs: (
            self.assertTrue(active) or registration)
        context.processes = {}

        @contextmanager
        def deferred():
            nonlocal active
            active = True
            try:
                yield
            finally:
                self.assertIs(context.processes[registration.process_key], process)
                active = False
                raise KeyboardInterrupt("pending signal delivered after admission")

        with mock.patch.object(bridge, "_defer_termination_signals", deferred):
            with self.assertRaisesRegex(KeyboardInterrupt, "after admission"):
                context.spawn_adapter(("/tmp/adapter",), stdin=bridge.subprocess.PIPE)

    def test_fixture_spawn_defers_termination_until_handle_and_registration_are_owned(self):
        active = False
        process = types.SimpleNamespace(pid=43)
        registration = types.SimpleNamespace(process_key="helper-key")
        context = object.__new__(bridge._Context)
        context.closed = False
        context.registry = types.SimpleNamespace(registrations=())
        context.processes = {}
        context.register = lambda *args, **kwargs: (
            self.assertTrue(active) or registration)

        def launcher(*args, **kwargs):
            self.assertTrue(active)
            return process

        @contextmanager
        def deferred():
            nonlocal active
            active = True
            try:
                yield
            finally:
                self.assertIs(context.processes[registration.process_key], process)
                active = False
                raise KeyboardInterrupt("pending signal delivered after admission")

        with mock.patch.object(bridge, "_defer_termination_signals", deferred):
            with self.assertRaisesRegex(KeyboardInterrupt, "after admission"):
                context.spawn_fixture(
                    "/tmp/helper", Path("/tmp/control"), "N", 1,
                    "sha256:" + "a" * 64, launcher)

    def test_run_admission_reconciles_before_pending_signal_is_delivered(self):
        order = []
        run = object.__new__(bridge.WS18RunContext)
        run.reconcile_process_admission = lambda: order.append("reconciled")

        @contextmanager
        def deferred():
            order.append("deferred")
            try:
                yield
            finally:
                order.append("signal-delivered")
                raise KeyboardInterrupt("pending signal")

        with mock.patch.object(bridge, "_defer_termination_signals", deferred):
            with self.assertRaisesRegex(KeyboardInterrupt, "pending signal"):
                with run.admission_boundary():
                    order.append("operation")

        self.assertEqual(order, [
            "deferred", "operation", "reconciled", "signal-delivered",
        ])

    def test_run_admission_reads_one_secure_run_owned_fixture_pid(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            root.chmod(0o700)
            path = root / "main.events.jsonl"
            path.write_text(json.dumps({
                "schema": bridge.drivers.FIXTURE_SCHEMA,
                "sequence": 1,
                "pid": 4242,
                "nonce": "N",
                "role": "main",
                "operation": "ready",
                "result": "ok",
            }) + "\n")
            path.chmod(0o600)
            run = object.__new__(bridge.WS18RunContext)
            run.mode = "launch"
            run.control_dir = root
            run.started_after_ns = 1
            run.authorization = types.SimpleNamespace(nonce="N")

            self.assertEqual(run._fixture_event_pid(), 4242)

    def test_launch_reconciliation_fails_closed_without_an_admissible_target(self):
        class Registry:
            registrations = ()
            def by_role(self, role): raise KeyError(role)
        run = object.__new__(bridge.WS18RunContext)
        run.mode = "launch"
        run._closed = False
        run.context = types.SimpleNamespace(
            registry=Registry(),
            observe_debugger_descendants=lambda: (),
        )
        run._fixture_event_pid = lambda: None

        with mock.patch.object(bridge.time, "sleep"):
            with self.assertRaisesRegex(bridge.RuntimeBridgeError, "launch target"):
                run.reconcile_process_admission()

    def test_cli_launch_readiness_join_precedes_admission(self):
        entered = threading.Event()
        release = threading.Event()
        order = []
        run = object.__new__(bridge.WS18RunContext)
        run._closed = False
        run.mode = "launch"
        run._cli_launch_readiness_thread = None
        run._cli_launch_readiness_pid = None
        run._cli_launch_readiness_timeout = 0.0
        run._cli_launch_readiness_error = None
        run._launch_proven_pid = None
        run._launch_start_ns = None
        run._launch_control = None

        def prove(pid, timeout):
            self.assertEqual((pid, timeout), (42, 1.0))
            entered.set()
            self.assertTrue(release.wait(1.0))
            run._launch_proven_pid = pid
            run._launch_start_ns = 123
            run._launch_control = object()
            order.append("prove")

        run._prove_launch_origin = prove
        run._admit_launch_target = lambda pid: order.append("admit")
        run._begin_cli_launch_readiness(42, 1.0)
        self.assertTrue(entered.wait(1.0))

        outcome = []
        waiter = threading.Thread(
            target=lambda: outcome.append(run._await_cli_launch_readiness(
                42, timeout=1.0)))
        waiter.start()
        self.assertEqual(order, [])
        release.set()
        waiter.join(1.0)
        self.assertFalse(waiter.is_alive())
        self.assertEqual(outcome, [None])
        run._admit_launch_target(42)
        self.assertEqual(order, ["prove", "admit"])

    def test_cli_launch_readiness_error_fails_closed_without_admission(self):
        run = object.__new__(bridge.WS18RunContext)
        run._closed = False
        run.mode = "launch"
        run._cli_launch_readiness_thread = None
        run._cli_launch_readiness_pid = None
        run._cli_launch_readiness_timeout = 0.0
        run._cli_launch_readiness_error = None
        run._launch_proven_pid = None
        run._launch_start_ns = None
        run._launch_control = None
        run._prove_launch_origin = lambda pid, timeout: (_ for _ in ()).throw(
            bridge.RuntimeBridgeError("ready mismatch"))
        run._begin_cli_launch_readiness(42, 1.0)
        with self.assertRaisesRegex(bridge.RuntimeBridgeError, "ready mismatch"):
            run._await_cli_launch_readiness(42, timeout=1.0)

    def test_cli_launch_readiness_rejects_duplicate_begin(self):
        entered = threading.Event()
        release = threading.Event()
        run = object.__new__(bridge.WS18RunContext)
        run._closed = False
        run.mode = "launch"
        run._cli_launch_readiness_thread = None
        run._cli_launch_readiness_pid = None
        run._cli_launch_readiness_timeout = 0.0
        run._cli_launch_readiness_error = None
        run._launch_proven_pid = None
        run._launch_start_ns = None
        run._launch_control = None

        def prove(pid, timeout):
            entered.set()
            self.assertTrue(release.wait(1.0))
            run._launch_proven_pid = pid
            run._launch_start_ns = 123
            run._launch_control = object()

        run._prove_launch_origin = prove
        run._begin_cli_launch_readiness(42, 1.0)
        self.assertTrue(entered.wait(1.0))
        with self.assertRaisesRegex(bridge.RuntimeBridgeError, "already active"):
            run._begin_cli_launch_readiness(43, 1.0)
        release.set()
        run._await_cli_launch_readiness(42, timeout=1.0)

    def test_launch_reconciliation_admits_cached_proven_pid_before_fallback(self):
        target_identity = types.SimpleNamespace(
            pid=42, role=bridge.supervision.ProcessRole.LAUNCHED_TARGET)
        target = types.SimpleNamespace(identity=target_identity)
        class Registry:
            def __init__(self): self.registrations = []
            def by_role(self, role):
                for item in self.registrations:
                    if item.identity.role is role:
                        return item
                raise KeyError(role)
        registry = Registry()
        admissions = []
        run = object.__new__(bridge.WS18RunContext)
        run.mode = "launch"
        run._closed = False
        run._launch_proven_pid = 42
        run._cli_launch_readiness_thread = None
        run._unpublished_launch_aborted = False
        run.authorization = types.SimpleNamespace(path="/tmp/fixture")
        run.context = types.SimpleNamespace(
            registry=registry,
            observe_debugger_descendants=lambda: (),
            inspector=types.SimpleNamespace(capture=lambda pid:
                bridge.supervision.ProcessSnapshot(
                    bridge.supervision.InspectionState.EXACT, target_identity,
                    bridge.supervision.ProcessTopology(1, pid, pid))),
            child_enumerator=types.SimpleNamespace(
                enumerate_debugserver_children=lambda *args, **kwargs:
                    (_ for _ in ()).throw(AssertionError("fallback used"))),
        )
        run._prove_launch_origin = lambda pid: None
        def admit(pid):
            admissions.append(pid)
            registry.registrations.append(target)
        run._admit_launch_target = admit

        run.reconcile_process_admission()

        self.assertEqual(admissions, [42])

    def test_python_launch_reconciliation_accepts_exact_terminal_unpublished_abort(self):
        class Registry:
            registrations = ()
            def by_role(self, role): raise KeyError(role)
        run = object.__new__(bridge.WS18RunContext)
        run.candidate = "xcode-lldb-python-json"
        run.mode = "launch"
        run._closed = False
        run._unpublished_launch_aborted = False
        run.context = types.SimpleNamespace(
            registry=Registry(),
            observe_debugger_descendants=lambda: (),
        )
        proof = {
            "operation": "configuredLaunch",
            "ownership": "none",
            "targetDisposition": "exited",
            "result": {},
            "evidence": {"cleanup": {
                "killRequested": True,
                "complete": True,
                "targetDisposition": "exited",
            }},
        }

        run.accept_unpublished_launch_abort(proof)
        run.reconcile_process_admission()

        self.assertTrue(run._unpublished_launch_aborted)

    def test_python_launch_reconciliation_rejects_incomplete_unpublished_abort(self):
        run = object.__new__(bridge.WS18RunContext)
        run.candidate = "xcode-lldb-python-json"
        run.mode = "launch"
        run._closed = False
        run._unpublished_launch_aborted = False
        proof = {
            "operation": "configuredLaunch",
            "ownership": "none",
            "targetDisposition": "exited",
            "result": {},
            "evidence": {"cleanup": {
                "killRequested": True,
                "complete": False,
                "targetDisposition": "exited",
            }},
        }

        with self.assertRaisesRegex(
                bridge.RuntimeBridgeError, "unpublished launch abort proof"):
            run.accept_unpublished_launch_abort(proof)

    def test_launch_reconciliation_rechecks_origin_for_registered_target(self):
        target = types.SimpleNamespace(identity=types.SimpleNamespace(
            pid=42, role=bridge.supervision.ProcessRole.LAUNCHED_TARGET))
        class Registry:
            registrations = (target,)
            def by_role(self, role): return target
        run = object.__new__(bridge.WS18RunContext)
        run.mode = "launch"
        run._closed = False
        run.context = types.SimpleNamespace(
            registry=Registry(), observe_debugger_descendants=lambda: ())
        run._prove_launch_origin = lambda pid: (_ for _ in ()).throw(
            bridge.RuntimeBridgeError("readiness unavailable"))

        with self.assertRaisesRegex(
                bridge.RuntimeBridgeError, "readiness unavailable"):
            run.reconcile_process_admission()

    def test_launch_reconciliation_attempts_debugserver_admission_after_event_error(self):
        observed = []
        debugserver = types.SimpleNamespace(
            identity=types.SimpleNamespace(
                pid=41, role=bridge.supervision.ProcessRole.LOCAL_DEBUGSERVER))
        class Registry:
            registrations = (debugserver,)
            def by_role(self, role): raise KeyError(role)
        run = object.__new__(bridge.WS18RunContext)
        run.mode = "launch"
        run._closed = False
        run.authorization = types.SimpleNamespace(path="/tmp/fixture")
        run.context = types.SimpleNamespace(
            registry=Registry(),
            observe_debugger_descendants=lambda: observed.append("debugserver") or (),
            child_enumerator=types.SimpleNamespace(
                enumerate_debugserver_children=lambda *args, **kwargs: (
                    types.SimpleNamespace(pid=42, canonical_path="/tmp/fixture"),)),
        )
        run._admit_launch_target = lambda pid: (_ for _ in ()).throw(
            bridge.RuntimeBridgeError("event invalid"))

        with self.assertRaisesRegex(bridge.RuntimeBridgeError, "event invalid"):
            run.reconcile_process_admission()
        self.assertEqual(observed, ["debugserver"])

    def test_launch_reconciliation_admits_exact_debugserver_child_target(self):
        debugserver = types.SimpleNamespace(
            identity=types.SimpleNamespace(
                pid=41, role=bridge.supervision.ProcessRole.LOCAL_DEBUGSERVER))
        target_registration = types.SimpleNamespace(
            identity=types.SimpleNamespace(
                pid=42, role=bridge.supervision.ProcessRole.LAUNCHED_TARGET))
        class Registry:
            def __init__(self): self.registrations = [debugserver]
            def by_role(self, role):
                for item in self.registrations:
                    if item.identity.role is role:
                        return item
                raise KeyError(role)
        registry = Registry()
        admissions = []
        def admit_target(pid):
            admissions.append(pid)
            registry.registrations.append(target_registration)
            return target_registration
        enumerator = types.SimpleNamespace(
            enumerate_debugserver_children=lambda parent, excluded_pids: (
                types.SimpleNamespace(pid=42, canonical_path="/tmp/fixture"),))
        run = object.__new__(bridge.WS18RunContext)
        run.mode = "launch"
        run._closed = False
        run.authorization = types.SimpleNamespace(
            path="/tmp/fixture", nonce="N", executable_identity="exec")
        run.context = types.SimpleNamespace(
            registry=registry,
            observe_debugger_descendants=lambda: (debugserver,),
            child_enumerator=enumerator,
        )
        run._admit_launch_target = admit_target

        with mock.patch.object(bridge.time, "sleep"):
            run.reconcile_process_admission()

        self.assertEqual(admissions, [42])

    def test_launch_origin_rejects_stale_process_before_registry_authority(self):
        calls = []
        class Control:
            def __init__(self, *args, **kwargs): self.event_path = Path("/tmp/events")
            def open(self, timeout): calls.append(("open", timeout))
            def _events(self):
                return [{"operation": "ready", "result": "ok"}]
            def close(self): calls.append(("close",))
        run = object.__new__(bridge.WS18RunContext)
        run.mode = "launch"
        run._launch_control = None
        run._launch_proven_pid = None
        run.control_dir = Path("/tmp")
        run.started_after_ns = 2_000_000_000
        run.authorization = types.SimpleNamespace(nonce="N")
        ensure_target = mock.Mock()
        run.context = types.SimpleNamespace(
            process_api=types.SimpleNamespace(bsd_info=lambda pid:
                types.SimpleNamespace(pid=pid, start_seconds=1,
                                      start_microseconds=0)),
            ensure_target=ensure_target,
        )
        with mock.patch.object(bridge.drivers, "FixtureControlClient", Control):
            with self.assertRaisesRegex(bridge.RuntimeBridgeError, "predates this run"):
                run._admit_launch_target(4242)

        ensure_target.assert_not_called()
        self.assertEqual(calls, [])

    def test_launch_origin_rejects_mismatched_ready_identity_before_registry(self):
        class Control:
            def __init__(self, *args, **kwargs): self.event_path = Path("/tmp/events")
            def open(self, timeout): pass
            def _events(self):
                raise bridge.drivers.DriverError("fixture event identity mismatch")
            def close(self): pass
        run = object.__new__(bridge.WS18RunContext)
        run.mode = "launch"
        run._launch_control = None
        run._launch_proven_pid = None
        run.control_dir = Path("/tmp")
        run.started_after_ns = 1
        run.authorization = types.SimpleNamespace(nonce="N")
        ensure_target = mock.Mock()
        run.context = types.SimpleNamespace(
            process_api=types.SimpleNamespace(bsd_info=lambda pid:
                types.SimpleNamespace(pid=pid, start_seconds=1,
                                      start_microseconds=0)),
            ensure_target=ensure_target)
        with mock.patch.object(bridge.drivers, "FixtureControlClient", Control):
            with self.assertRaisesRegex(
                    bridge.drivers.DriverError, "identity mismatch"):
                run._admit_launch_target(4242)
        ensure_target.assert_not_called()

    def test_launch_origin_rejects_pid_reuse_across_ready_event(self):
        class Control:
            def __init__(self, *args, **kwargs): self.event_path = Path("/tmp/events")
            def open(self, timeout): pass
            def _events(self): return [{"operation": "ready", "result": "ok"}]
            def close(self): pass
        starts = iter((1, 2))
        run = object.__new__(bridge.WS18RunContext)
        run.mode = "launch"
        run._launch_control = None
        run._launch_proven_pid = None
        run.control_dir = Path("/tmp")
        run.started_after_ns = 1
        run.authorization = types.SimpleNamespace(nonce="N")
        ensure_target = mock.Mock()
        run.context = types.SimpleNamespace(
            process_api=types.SimpleNamespace(bsd_info=lambda pid:
                types.SimpleNamespace(pid=pid, start_seconds=next(starts),
                                      start_microseconds=0)),
            ensure_target=ensure_target)

        with mock.patch.object(bridge.drivers, "FixtureControlClient", Control):
            with self.assertRaisesRegex(
                    bridge.RuntimeBridgeError, "changed across readiness"):
                run._admit_launch_target(4242)
        ensure_target.assert_not_called()

    def test_launch_origin_uses_one_deadline_across_open_and_ready_event(self):
        calls = []
        class Control:
            def __init__(self, *args, **kwargs): pass
            def open(self, timeout): calls.append(("open", timeout))
            def _events(self):
                calls.append(("events",))
                return []
            def close(self): calls.append(("close",))
        run = object.__new__(bridge.WS18RunContext)
        run.mode = "launch"
        run._launch_control = None
        run._launch_proven_pid = None
        run.control_dir = Path("/tmp")
        run.started_after_ns = 1
        run.authorization = types.SimpleNamespace(nonce="N")
        run.context = types.SimpleNamespace(
            process_api=types.SimpleNamespace(bsd_info=lambda pid:
                types.SimpleNamespace(pid=pid, start_seconds=1,
                                      start_microseconds=0)))

        with mock.patch.object(bridge.drivers, "FixtureControlClient", Control), \
                mock.patch.object(
                    bridge.time, "monotonic", side_effect=(100.0, 100.8, 101.1)):
            with self.assertRaisesRegex(
                    bridge.RuntimeBridgeError, "readiness evidence"):
                run._prove_launch_origin(4242, timeout=1.0)

        self.assertAlmostEqual(calls[0][1], 0.2)
        self.assertEqual(calls[1:], [("close",)])

    def test_cli_post_detach_probe_reuses_exact_attach_authority(self):
        run = object.__new__(bridge.WS18RunContext)
        run.mode = "attach"
        run._attach_target = types.SimpleNamespace(pid=42)
        run.python_attach_identity = lambda: {"pid": 42, "nonce": "N"}
        observed = []
        run._python_detach_observer = lambda identity, pid: (
            observed.append((identity, pid)) or {
                "sameIdentity": True, "alive": True, "controllable": True,
                "checkpointSequence": 2, "pid": pid,
            })

        proof = run.post_detach_probe(42)

        self.assertEqual(observed, [({"pid": 42, "nonce": "N"}, 42)])
        self.assertTrue(proof["sameIdentity"])
        self.assertEqual(proof["checkpointSequence"], 2)

    def test_graceful_adapter_terminates_and_reaps_exact_direct_child(self):
        calls = []
        class Input:
            closed = False
            def close(self):
                self.closed = True
                calls.append(("stdin-close",))
        class Process:
            stdin = Input()
            def poll(self):
                calls.append(("poll",))
                return None
            def terminate(self):
                calls.append(("terminate",))
            def wait(self, timeout):
                calls.append(("wait", timeout))
                return 0
        registration = types.SimpleNamespace(process_key="adapter-key")
        context = object.__new__(bridge._Context)
        context.processes = {registration.process_key: Process()}

        receipt = context._graceful_adapter(registration, 0.75)

        self.assertEqual(calls, [
            ("poll",), ("stdin-close",), ("terminate",), ("wait", 0.75),
        ])
        self.assertTrue(receipt.requested)
        self.assertTrue(receipt.acknowledged)
        self.assertEqual(receipt.action, "terminateExactAdapter")

    def test_graceful_adapter_reports_bounded_reap_timeout(self):
        class Process:
            args = ("/SelectedXcode/lldb-dap",)
            def poll(self): return None
            def terminate(self): pass
            def wait(self, timeout):
                raise bridge.subprocess.TimeoutExpired(self.args, timeout)
        registration = types.SimpleNamespace(process_key="adapter-key")
        context = object.__new__(bridge._Context)
        context.processes = {registration.process_key: Process()}

        receipt = context._graceful_adapter(registration, 0.5)

        self.assertTrue(receipt.requested)
        self.assertFalse(receipt.acknowledged)
        self.assertEqual(receipt.action, "terminateExactAdapterTimedOut")
        self.assertIn("0.5 seconds", receipt.detail)

    def test_graceful_adapter_does_not_signal_already_reaped_child(self):
        class Process:
            def poll(self): return 0
            def terminate(self): raise AssertionError("must not terminate")
            def wait(self, timeout): raise AssertionError("must not wait")
        registration = types.SimpleNamespace(process_key="adapter-key")
        context = object.__new__(bridge._Context)
        context.processes = {registration.process_key: Process()}

        receipt = context._graceful_adapter(registration, 0.5)

        self.assertFalse(receipt.requested)
        self.assertTrue(receipt.acknowledged)
        self.assertEqual(receipt.action, "alreadyExited")

    def test_fixture_exit_reaps_retained_attach_helper(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            event_path = root / "helper.events.jsonl"
            event_path.write_text('{"commandSequence":0}\n')
            calls = []
            class Process:
                def wait(self, timeout):
                    calls.append(("wait", timeout))
                    return 0
            class Control:
                def __init__(self, control_dir, role, nonce, target_pid):
                    pass
                def _events(self):
                    return [{"commandSequence": 0}]
                def send(self, operation, timeout):
                    calls.append(("send", operation, timeout))
                def close(self):
                    calls.append(("close",))
            registration = types.SimpleNamespace(
                process_key="helper-key",
                identity=types.SimpleNamespace(nonce="N", pid=42),
            )
            run = object.__new__(bridge.WS18RunContext)
            run.mode = "attach"
            run.control_dir = root
            run.context = types.SimpleNamespace(
                processes={registration.process_key: Process()})
            original_client = bridge.drivers.FixtureControlClient
            bridge.drivers.FixtureControlClient = Control
            try:
                receipt = run._fixture_exit(registration, 0.75)
            finally:
                bridge.drivers.FixtureControlClient = original_client

            self.assertEqual(calls, [
                ("send", "exit", 0.75), ("wait", 0.75), ("close",),
            ])
            self.assertTrue(receipt.requested)
            self.assertTrue(receipt.acknowledged)
            self.assertEqual(receipt.action, "fixtureExit")

    def test_fixture_exit_rejects_oversize_event_before_unbounded_allocation(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            event_path = root / "helper.events.jsonl"
            with event_path.open("wb") as stream:
                stream.truncate(bridge.drivers.MAX_FIXTURE_EVENT_BYTES + 1)
            event_path.chmod(0o600)
            registration = types.SimpleNamespace(
                process_key="helper-key",
                identity=types.SimpleNamespace(nonce="N", pid=42),
            )
            run = object.__new__(bridge.WS18RunContext)
            run.mode = "attach"
            run.control_dir = root
            run.context = types.SimpleNamespace(processes={})
            with mock.patch.object(
                    Path, "read_bytes",
                    side_effect=AssertionError("unbounded Path.read_bytes used")):
                receipt = run._fixture_exit(registration, 0.1)

            self.assertTrue(receipt.requested)
            self.assertFalse(receipt.acknowledged)
            self.assertEqual(receipt.action, "fixtureExitFailed")
            self.assertIn("exceeds configured bound", receipt.detail)

    def test_descendant_registration_reports_both_snapshot_failures(self):
        context = object.__new__(bridge._Context)
        context.closed = False
        context.claims = bridge.darwin.SelectedProcessClaims()
        context.registry = types.SimpleNamespace()
        canonical_path = os.path.realpath("/tmp/Selected Xcode/debugserver")
        adapter_registration = types.SimpleNamespace(
            process_key="adapter-key",
            identity=types.SimpleNamespace(pid=400),
        )
        snapshots = {
            401: bridge.supervision.ProcessSnapshot(
                bridge.supervision.InspectionState.UNSTABLE,
                detail="descendant changed during A-B-A capture",
            ),
            400: bridge.supervision.ProcessSnapshot(
                bridge.supervision.InspectionState.UNINSPECTABLE,
                detail="adapter inspection denied",
            ),
        }
        context.inspector = types.SimpleNamespace(
            capture=lambda pid: snapshots[pid])

        with self.assertRaises(bridge.RuntimeBridgeError) as raised:
            context.register_debugger_descendant(
                401, canonical_path, "debugger-child-401", adapter_registration)

        prefix = "debugger descendant identity is not exact: "
        self.assertTrue(str(raised.exception).startswith(prefix))
        self.assertEqual(json.loads(str(raised.exception)[len(prefix):]), {
            "pid": 401,
            "path": canonical_path,
            "descendantState": "unstableSnapshot",
            "descendantDetail": "descendant changed during A-B-A capture",
            "adapterState": "uninspectable",
            "adapterDetail": "adapter inspection denied",
        })

    def test_descendant_registration_bounds_snapshot_failure_details(self):
        context = object.__new__(bridge._Context)
        context.closed = False
        context.claims = bridge.darwin.SelectedProcessClaims()
        context.registry = types.SimpleNamespace()
        adapter_registration = types.SimpleNamespace(
            process_key="adapter-key",
            identity=types.SimpleNamespace(pid=400),
        )
        oversized = "x" * (bridge.supervision.MAX_DETAIL_BYTES + 100)
        snapshots = {
            401: bridge.supervision.ProcessSnapshot(
                bridge.supervision.InspectionState.UNSTABLE, detail=oversized),
            400: bridge.supervision.ProcessSnapshot(
                bridge.supervision.InspectionState.GONE, detail=oversized),
        }
        context.inspector = types.SimpleNamespace(
            capture=lambda pid: snapshots[pid])

        with self.assertRaises(bridge.RuntimeBridgeError) as raised:
            context.register_debugger_descendant(
                401, "/tmp/debugserver", "debugger-child-401",
                adapter_registration)

        prefix = "debugger descendant identity is not exact: "
        self.assertTrue(str(raised.exception).startswith(prefix))
        diagnostic = json.loads(str(raised.exception)[len(prefix):])
        self.assertEqual(
            len(diagnostic["descendantDetail"].encode("utf-8")),
            bridge.supervision.MAX_DETAIL_BYTES,
        )
        self.assertEqual(
            len(diagnostic["adapterDetail"].encode("utf-8")),
            bridge.supervision.MAX_DETAIL_BYTES,
        )

    def test_cli_open_composes_registered_process_pipes_into_exchange_channel(self):
        class Context:
            stderr = None
            def spawn_adapter(self, argv, stdin, stderr):
                self.stderr = stderr
                process = subprocess.Popen(
                    (sys.executable, "-u", "-c",
                     "import sys\nfor line in sys.stdin:\n sys.stdout.write(line); sys.stdout.flush()"),
                    stdin=stdin, stdout=subprocess.PIPE, stderr=stderr,
                    start_new_session=True, close_fds=True,
                )
                return process, "REGISTRATION"

        context = Context()
        lifecycle = bridge._CLILifecycle(context)
        channel, registration = lifecycle.open_cli_session(("/tmp/lldb", "--no-lldbinit"))
        process = channel.process
        try:
            self.assertEqual(registration, "REGISTRATION")
            self.assertIs(context.stderr, subprocess.STDOUT)
            self.assertEqual(channel.exchange(
                "BEGIN\nEND\n", begin_marker="BEGIN", end_marker="END",
                timeout=1.0, max_bytes=128,
            ), "BEGIN\nEND\n")
        finally:
            process.terminate()
            process.wait(timeout=1.0)
            channel.close_pipes()

    def test_registration_failure_only_terminates_proven_unreaped_direct_child(self):
        class Process:
            pid = 91
            terminated = False
            def poll(self): return None
            def terminate(self): self.terminated = True
            def wait(self, timeout): return 0
        process = Process()
        context = object.__new__(bridge._Context)
        context.owner = "test"
        context.processes = {}
        context.process_factory = lambda *args, **kwargs: process
        context.register = lambda *args, **kwargs: (_ for _ in ()).throw(
            bridge.RuntimeBridgeError("registration failed"))
        with self.assertRaisesRegex(bridge.RuntimeBridgeError, "registration failed"):
            context.spawn_adapter(("/tmp/adapter",), stdin=bridge.subprocess.PIPE)
        self.assertTrue(process.terminated)

    def test_registration_failure_escalates_only_same_unreaped_direct_child(self):
        class Process:
            pid = 92
            terminated = False
            killed = False
            waits = 0
            def poll(self): return None
            def terminate(self): self.terminated = True
            def kill(self): self.killed = True
            def wait(self, timeout):
                self.waits += 1
                if self.waits == 1:
                    raise bridge.subprocess.TimeoutExpired(("adapter",), timeout)
                return 0
        process = Process()
        context = object.__new__(bridge._Context)
        context.owner = "test"
        context.processes = {}
        context.process_factory = lambda *args, **kwargs: process
        context.register = lambda *args, **kwargs: (_ for _ in ()).throw(
            bridge.RuntimeBridgeError("registration failed"))
        with self.assertRaisesRegex(bridge.RuntimeBridgeError, "registration failed"):
            context.spawn_adapter(("/tmp/adapter",), stdin=bridge.subprocess.PIPE)
        self.assertTrue(process.terminated)
        self.assertTrue(process.killed)
        self.assertEqual(process.waits, 2)

    def test_retired_one_shot_cli_rejects_before_adapter_spawn(self):
        class Context:
            spawn_count = 0
            def spawn_adapter(self, argv, stdin):
                self.spawn_count += 1
                raise AssertionError("retired path must not spawn")
        context = Context()
        lifecycle = bridge._CLILifecycle(context)
        with self.assertRaisesRegex(bridge.RuntimeBridgeError, "retired"):
            lifecycle.execute_and_cleanup(
                ("/tmp/lldb", "--batch", "-o", "process launch"), 1.0)
        self.assertEqual(context.spawn_count, 0)

    def test_command_bearing_persistent_cli_profile_rejects_before_spawn(self):
        class Context:
            spawn_count = 0
            def spawn_adapter(self, argv, **options):
                self.spawn_count += 1
                raise AssertionError("active adapter profile must not spawn")
        context = Context()
        lifecycle = bridge._CLILifecycle(context)
        with self.assertRaisesRegex(bridge.RuntimeBridgeError, "inert profile"):
            lifecycle.open_cli_session(
                ("/tmp/lldb", "--batch", "-o", "process launch"))
        self.assertEqual(context.spawn_count, 0)

    def test_command_bearing_python_profile_rejects_before_spawn(self):
        class Context:
            spawn_count = 0
            def spawn_adapter(self, argv, **options):
                self.spawn_count += 1
                raise AssertionError("active adapter profile must not spawn")
        context = Context()
        lifecycle = bridge._PythonLifecycle(context)
        with self.assertRaisesRegex(bridge.RuntimeBridgeError, "inert child profile"):
            lifecycle.spawn_and_register(
                ("/usr/bin/python3", "/tmp/other.py", "--launch"), {})
        self.assertEqual(context.spawn_count, 0)

    def test_adapter_cleanup_is_at_most_once_and_does_not_close_run(self):
        adapter = types.SimpleNamespace(
            process_key="adapter-key",
            identity=types.SimpleNamespace(
                pid=400,
                role=bridge.supervision.ProcessRole.ADAPTER))
        receipt = types.SimpleNamespace(complete=True)
        supervisor = types.SimpleNamespace(calls=0)
        process = types.SimpleNamespace(polls=0)
        def poll():
            process.polls += 1
            return None
        process.poll = poll
        def clean(registration):
            self.assertEqual(process.polls, 1)
            supervisor.calls += 1
            return receipt
        supervisor._cleanup_one = clean
        context = object.__new__(bridge._Context)
        context.adapter_receipts = {}
        context.descendant_receipts = {}
        context.processes = {adapter.process_key: process}
        context.registry = types.SimpleNamespace(registrations=(adapter,))
        context.inspector = types.SimpleNamespace(capture=lambda pid:
            bridge.supervision.ProcessSnapshot(
                bridge.supervision.InspectionState.EXACT,
                adapter.identity,
                bridge.supervision.ProcessTopology(1, 400, 400)))
        context.child_enumerator = types.SimpleNamespace(
            enumerate=lambda registration, **kwargs: ())
        context.supervisor = supervisor
        context.closed = False

        self.assertIs(context.cleanup_adapter(adapter), receipt)
        self.assertIs(context.cleanup_adapter(adapter), receipt)
        self.assertEqual(supervisor.calls, 1)
        self.assertEqual(process.polls, 1)
        self.assertFalse(context.closed)

    def test_candidate_adapter_close_cannot_cleanup_attached_helper(self):
        adapter = types.SimpleNamespace(process_key="adapter",
            identity=types.SimpleNamespace(role=bridge.supervision.ProcessRole.ADAPTER))
        helper = types.SimpleNamespace(process_key="helper",
            identity=types.SimpleNamespace(role=bridge.supervision.ProcessRole.ATTACHED_HELPER))
        class Context:
            cleaned = []
            def cleanup_adapter(self, registration):
                self.cleaned.append(registration.process_key)
                return types.SimpleNamespace(complete=True)
        context = Context()
        lifecycle = bridge._CLILifecycle(context)
        lifecycle.close_cli_session(adapter)
        self.assertEqual(context.cleaned, ["adapter"])
        self.assertNotIn(helper.process_key, context.cleaned)

    def test_adapter_cleanup_discovers_and_cleans_exact_child_before_adapter(self):
        adapter = types.SimpleNamespace(
            process_key="adapter-key",
            identity=types.SimpleNamespace(
                role=bridge.supervision.ProcessRole.ADAPTER))
        descendant = types.SimpleNamespace(
            process_key="debugserver-key",
            identity=types.SimpleNamespace(
                role=bridge.supervision.ProcessRole.LOCAL_DEBUGSERVER))
        order = []
        receipt = types.SimpleNamespace(complete=True)
        context = object.__new__(bridge._Context)
        context.adapter_receipts = {}
        context.descendant_receipts = {}
        context.processes = {}
        context.closed = False
        context.discover_debugger_descendants = lambda registration: (descendant,)
        context.supervisor = types.SimpleNamespace(
            _cleanup_one=lambda registration: order.append(registration.process_key) or receipt)

        self.assertIs(context.cleanup_adapter(adapter), receipt)
        self.assertEqual(order, ["debugserver-key", "adapter-key"])

    def test_adapter_cleanup_consumes_late_registered_child_after_adapter_receipt(self):
        adapter = types.SimpleNamespace(
            process_key="adapter-key",
            identity=types.SimpleNamespace(
                role=bridge.supervision.ProcessRole.ADAPTER))
        descendant = types.SimpleNamespace(
            process_key="debugserver-key",
            identity=types.SimpleNamespace(
                role=bridge.supervision.ProcessRole.LOCAL_DEBUGSERVER))
        adapter_receipt = types.SimpleNamespace(complete=True)
        descendant_receipt = types.SimpleNamespace(complete=True)
        cleaned = []
        context = object.__new__(bridge._Context)
        context.adapter_receipts = {adapter.process_key: adapter_receipt}
        context.descendant_receipts = {}
        context.processes = {}
        context.closed = False
        context.discover_debugger_descendants = lambda registration: (descendant,)
        context.supervisor = types.SimpleNamespace(
            _cleanup_one=lambda registration: (
                cleaned.append(registration.process_key) or descendant_receipt))

        self.assertIs(context.cleanup_adapter(adapter), adapter_receipt)
        self.assertEqual(cleaned, ["debugserver-key"])
        self.assertIs(
            context.descendant_receipts[descendant.process_key],
            descendant_receipt,
        )

    def test_adapter_cleanup_reconciles_a_b_a_disappearance_with_followup_gone(self):
        key = bridge.supervision.ProcessKey(400, 1, 2, 3, 4)
        identity = types.SimpleNamespace(
            pid=400, role=bridge.supervision.ProcessRole.ADAPTER)
        adapter = types.SimpleNamespace(process_key=key, identity=identity)
        receipt = bridge.supervision.CleanupReceipt(
            key, bridge.supervision.ProcessRole.ADAPTER, "owner", 1,
            bridge.supervision.InspectionState.UNSTABLE, "refused", False,
            bridge.supervision.InspectionState.UNSTABLE, False, False,
            bridge.supervision.InspectionState.UNSTABLE, False,
            "refused unstableSnapshot identity", "process disappeared")
        context = object.__new__(bridge._Context)
        context.adapter_receipts = {}
        context.descendant_receipts = {}
        context.processes = {}
        context.closed = False
        context.discover_debugger_descendants = lambda registration: ()
        process = types.SimpleNamespace(poll=lambda: 0)
        def terminal_receipt(registration, pre, graceful, after, term_attempted,
                             term_sent, final, complete):
            self.assertIs(pre.state, bridge.supervision.InspectionState.GONE)
            return replace(
                receipt,
                pre_action_state=pre.state,
                graceful_action=graceful.action,
                after_graceful_state=after.state,
                final_state=final.state,
                complete=complete,
                refusal="",
                observed_identity=identity,
            )
        context.supervisor = types.SimpleNamespace(
            _cleanup_one=lambda registration: self.fail(
                "reaped child must not enter generic cleanup"),
            _receipt=terminal_receipt,
            _refusal_for=lambda snapshot, expected: "")
        context.processes = {key: process}
        context.inspector = types.SimpleNamespace(capture=lambda pid:
            bridge.supervision.ProcessSnapshot.gone("no such process"))

        reconciled = context.cleanup_adapter(adapter)

        self.assertTrue(reconciled.complete)
        self.assertEqual(reconciled.graceful_action, "alreadyGone")
        self.assertIs(reconciled.pre_action_state,
                      bridge.supervision.InspectionState.GONE)
        self.assertIs(reconciled.observed_identity, identity)

    def test_adapter_cleanup_does_not_retry_identity_mismatch(self):
        key = bridge.supervision.ProcessKey(400, 1, 2, 3, 4)
        identity = types.SimpleNamespace(
            pid=400, role=bridge.supervision.ProcessRole.ADAPTER)
        adapter = types.SimpleNamespace(process_key=key, identity=identity)
        receipt = bridge.supervision.CleanupReceipt(
            key, bridge.supervision.ProcessRole.ADAPTER, "owner", 1,
            bridge.supervision.InspectionState.EXACT, "refused", False,
            bridge.supervision.InspectionState.EXACT, False, False,
            bridge.supervision.InspectionState.EXACT, False,
            "refused immutable identity mismatch", "identity changed")
        calls = []
        context = object.__new__(bridge._Context)
        context.adapter_receipts = {}
        context.descendant_receipts = {}
        context.processes = {}
        context.closed = False
        context.discover_debugger_descendants = lambda registration: ()
        context.supervisor = types.SimpleNamespace(
            _cleanup_one=lambda registration: calls.append(registration) or receipt)

        self.assertIs(context.cleanup_adapter(adapter), receipt)
        self.assertEqual(calls, [adapter])

    def test_adapter_cleanup_preserves_unstable_receipt_while_child_is_alive(self):
        key = bridge.supervision.ProcessKey(400, 1, 2, 3, 4)
        adapter = types.SimpleNamespace(
            process_key=key, identity=types.SimpleNamespace(
                pid=400, role=bridge.supervision.ProcessRole.ADAPTER))
        receipt = bridge.supervision.CleanupReceipt(
            key, bridge.supervision.ProcessRole.ADAPTER, "owner", 1,
            bridge.supervision.InspectionState.UNSTABLE, "refused", False,
            bridge.supervision.InspectionState.UNSTABLE, False, False,
            bridge.supervision.InspectionState.UNSTABLE, False,
            "refused unstableSnapshot identity", "unstable")
        context = object.__new__(bridge._Context)
        context.adapter_receipts = {}
        context.descendant_receipts = {}
        context.processes = {key: types.SimpleNamespace(poll=lambda: None)}
        context.closed = False
        context.discover_debugger_descendants = lambda registration: ()
        context.supervisor = types.SimpleNamespace(
            _cleanup_one=lambda registration: receipt,
            _receipt=lambda *args: self.fail("must not reconcile live child"),
            _refusal_for=lambda *args: self.fail("must not inspect live child here"))

        self.assertIs(context.cleanup_adapter(adapter), receipt)

    def test_adapter_cleanup_refuses_single_non_gone_capture_after_reap(self):
        key = bridge.supervision.ProcessKey(400, 1, 2, 3, 4)
        identity = types.SimpleNamespace(
            pid=400, role=bridge.supervision.ProcessRole.ADAPTER)
        adapter = types.SimpleNamespace(process_key=key, identity=identity)
        unstable = bridge.supervision.ProcessSnapshot(
            bridge.supervision.InspectionState.UNSTABLE,
            detail="PID changed during capture")
        captured = []
        refused = types.SimpleNamespace(complete=False, refusal="unstable")
        context = object.__new__(bridge._Context)
        context.adapter_receipts = {}
        context.descendant_receipts = {}
        context.processes = {key: types.SimpleNamespace(poll=lambda: 0)}
        context.closed = False
        context.discover_debugger_descendants = lambda registration: ()
        context.inspector = types.SimpleNamespace(capture=lambda pid:
            captured.append(pid) or unstable)
        context.supervisor = types.SimpleNamespace(
            _cleanup_one=lambda registration: self.fail(
                "reaped child must not enter generic cleanup"),
            _refusal_for=lambda snapshot, expected:
                "refused unstableSnapshot identity",
            _receipt=lambda *args: refused)

        self.assertIs(context.cleanup_adapter(adapter), refused)
        self.assertEqual(captured, [400])

    def test_descendant_discovery_registers_one_exact_direct_child_without_name_matching(self):
        adapter = types.SimpleNamespace(
            process_key="adapter-key",
            identity=types.SimpleNamespace(pid=400,
                role=bridge.supervision.ProcessRole.ADAPTER))
        observation = bridge.darwin.ExactChildObservation(
            401, 400, 10, 20, "/SelectedXcode/private/runtime-agent")
        registered = types.SimpleNamespace(
            process_key="debugserver-key",
            identity=types.SimpleNamespace(
                pid=401, canonical_path="/SelectedXcode/private/runtime-agent",
                start_seconds=10, start_microseconds=20))
        calls = []
        context = object.__new__(bridge._Context)
        context.registry = types.SimpleNamespace(registrations=(adapter,))
        context.inspector = types.SimpleNamespace(capture=lambda pid:
            bridge.supervision.ProcessSnapshot(
                bridge.supervision.InspectionState.EXACT,
                adapter.identity,
                bridge.supervision.ProcessTopology(1, 400, 400)))
        context.child_enumerator = types.SimpleNamespace(
            enumerate=lambda registration, **kwargs: (observation,))
        context.owner = "cli-launch"
        context.register_debugger_descendant = (
            lambda pid, path, nonce, registration, executable_identity="":
                calls.append((pid, path, nonce, registration)) or registered)

        self.assertEqual(context.discover_debugger_descendants(adapter), (registered,))
        self.assertEqual(calls, [(401, "/SelectedXcode/private/runtime-agent",
                                  "cli-launch-debugger-child-401", adapter)])

    def test_descendant_discovery_excludes_every_registered_pid_before_child_capture(self):
        adapter = types.SimpleNamespace(
            process_key="adapter-key",
            identity=types.SimpleNamespace(pid=400,
                role=bridge.supervision.ProcessRole.ADAPTER))
        target = types.SimpleNamespace(
            process_key="target-key",
            identity=types.SimpleNamespace(pid=401,
                role=bridge.supervision.ProcessRole.LAUNCHED_TARGET))
        observation = bridge.darwin.ExactChildObservation(
            402, 400, 10, 20, "/SelectedXcode/private/runtime-agent")
        registered = types.SimpleNamespace(
            process_key="debugserver-key",
            identity=types.SimpleNamespace(
                pid=402, canonical_path="/SelectedXcode/private/runtime-agent",
                start_seconds=10, start_microseconds=20))
        enumeration_calls = []
        context = object.__new__(bridge._Context)
        context.registry = types.SimpleNamespace(registrations=(adapter, target))
        context.inspector = types.SimpleNamespace(capture=lambda pid:
            bridge.supervision.ProcessSnapshot(
                bridge.supervision.InspectionState.EXACT,
                adapter.identity,
                bridge.supervision.ProcessTopology(1, 400, 400)))
        context.child_enumerator = types.SimpleNamespace(
            enumerate=lambda registration, *, excluded_pids: (
                enumeration_calls.append((registration, frozenset(excluded_pids)))
                or (observation,)
            ))
        context.owner = "dap-launch"
        context.register_debugger_descendant = (
            lambda pid, path, nonce, registration, executable_identity="": registered)

        self.assertEqual(context.discover_debugger_descendants(adapter), (registered,))
        self.assertEqual(enumeration_calls, [
            (adapter, frozenset({400, 401})),
        ])

    def test_descendant_discovery_fails_closed_for_ambiguous_direct_children(self):
        adapter = types.SimpleNamespace(
            process_key="adapter-key",
            identity=types.SimpleNamespace(pid=400,
                role=bridge.supervision.ProcessRole.ADAPTER))
        context = object.__new__(bridge._Context)
        context.registry = types.SimpleNamespace(registrations=(adapter,))
        context.inspector = types.SimpleNamespace(capture=lambda pid:
            bridge.supervision.ProcessSnapshot(
                bridge.supervision.InspectionState.EXACT,
                adapter.identity,
                bridge.supervision.ProcessTopology(1, 400, 400)))
        context.child_enumerator = types.SimpleNamespace(enumerate=lambda registration, **kwargs: (
            bridge.darwin.ExactChildObservation(401, 400, 10, 20, "/a"),
            bridge.darwin.ExactChildObservation(402, 400, 10, 20, "/b"),
        ))
        with self.assertRaisesRegex(bridge.RuntimeBridgeError, "ambiguous"):
            context.discover_debugger_descendants(adapter)

    def test_descendant_discovery_fails_closed_when_adapter_is_gone_before_child_admission(self):
        adapter = types.SimpleNamespace(
            process_key="adapter-key",
            identity=types.SimpleNamespace(pid=400,
                role=bridge.supervision.ProcessRole.ADAPTER))
        context = object.__new__(bridge._Context)
        context.registry = types.SimpleNamespace(registrations=(adapter,))
        context.inspector = types.SimpleNamespace(
            capture=lambda pid: bridge.supervision.ProcessSnapshot.gone())
        context.child_enumerator = types.SimpleNamespace(
            enumerate=lambda registration: self.fail(
                "gone adapter must not be used to fabricate child enumeration"))

        with self.assertRaisesRegex(
                bridge.RuntimeBridgeError,
                "adapter exited before debugger descendant admission"):
            context.discover_debugger_descendants(adapter)

    def test_adapter_cleanup_still_cleans_registered_descendant_after_adapter_crash(self):
        adapter = types.SimpleNamespace(
            process_key="adapter-key",
            identity=types.SimpleNamespace(pid=400,
                role=bridge.supervision.ProcessRole.ADAPTER))
        descendant = types.SimpleNamespace(
            process_key="debugserver-key",
            identity=types.SimpleNamespace(pid=401,
                role=bridge.supervision.ProcessRole.LOCAL_DEBUGSERVER))
        cleaned = []
        receipts = {
            adapter.process_key: types.SimpleNamespace(complete=True),
            descendant.process_key: types.SimpleNamespace(complete=True),
        }
        context = object.__new__(bridge._Context)
        context.adapter_receipts = {}
        context.descendant_receipts = {}
        context.processes = {}
        context.closed = False
        context.registry = types.SimpleNamespace(
            registrations=(adapter, descendant))
        context.supervisor = types.SimpleNamespace(
            _cleanup_one=lambda registration: (
                cleaned.append(registration.process_key)
                or receipts[registration.process_key]))

        self.assertIs(
            context.cleanup_adapter(adapter), receipts[adapter.process_key])
        self.assertEqual(cleaned, [descendant.process_key, adapter.process_key])

    def test_spawn_fixture_discards_non_authoritative_output(self):
        process = types.SimpleNamespace(pid=42, poll=lambda: None)
        captured = {}
        context = object.__new__(bridge._Context)
        context.closed = False
        context.registry = types.SimpleNamespace(registrations=())
        context.processes = {}
        context.register = lambda *args: types.SimpleNamespace(
            process_key="helper-key")

        def launcher(argv, **options):
            captured.update(options)
            return process

        registration = context.spawn_fixture(
            "/tmp/helper", Path("/tmp/control"), "N", 1,
            "sha256:" + "a" * 64, launcher)

        self.assertEqual(registration.process_key, "helper-key")
        self.assertIs(captured["stdout"], bridge.subprocess.DEVNULL)
        self.assertIs(captured["stderr"], bridge.subprocess.DEVNULL)

    def test_python_bridge_discards_non_protocol_stderr(self):
        captured = {}
        context = types.SimpleNamespace(
            spawn_adapter=lambda argv, **options: (
                captured.update(options) or ("PROCESS", "REGISTRATION")))

        process, registration = bridge._PythonLifecycle(
            context).spawn_and_register((
                sys.executable,
                str(Path(bridge.__file__).resolve().with_name("lldb_python_bridge.py")),
                "--child",
            ), {"A": "B"})

        self.assertEqual((process, registration), ("PROCESS", "REGISTRATION"))
        self.assertIs(captured["stdin"], bridge.subprocess.PIPE)
        self.assertIs(captured["stderr"], bridge.subprocess.DEVNULL)

    def test_context_cleanup_preserves_first_authoritative_adapter_and_descendant_receipts(self):
        adapter_key = "adapter-key"
        child_key = "debugserver-key"
        adapter_first = types.SimpleNamespace(process_key=adapter_key, complete=True,
            pre_action_state=bridge.supervision.InspectionState.EXACT)
        child_first = types.SimpleNamespace(process_key=child_key, complete=True,
            pre_action_state=bridge.supervision.InspectionState.EXACT)
        adapter_second = types.SimpleNamespace(process_key=adapter_key, complete=True,
            pre_action_state=bridge.supervision.InspectionState.GONE)
        child_second = types.SimpleNamespace(process_key=child_key, complete=True,
            pre_action_state=bridge.supervision.InspectionState.GONE)
        context = object.__new__(bridge._Context)
        context.closed = False
        context.adapter_receipts = {adapter_key: adapter_first}
        context.descendant_receipts = {child_key: child_first}
        context.supervisor = types.SimpleNamespace(
            cleanup_all=lambda: (child_second, adapter_second),
            audit_residue=lambda: types.SimpleNamespace(complete=True),
        )

        context.cleanup()
        self.assertEqual(context.cleanup_receipts, (child_first, adapter_first))
        self.assertTrue(context.closed)

    def test_context_cleanup_reconciles_exact_debugserver_exit_race_with_residue(self):
        key = bridge.supervision.ProcessKey(42, 1, 2, 3, 4)
        receipt = bridge.supervision.CleanupReceipt(
            key, bridge.supervision.ProcessRole.LOCAL_DEBUGSERVER, "owner", 1,
            bridge.supervision.InspectionState.EXACT,
            "noGracefulAction", False,
            bridge.supervision.InspectionState.EXACT,
            True, True, bridge.supervision.InspectionState.UNSTABLE,
            False, "", "process disappeared during final A-B-A capture",
            object(), True, True, object(), True,
        )
        residue = bridge.supervision.ResidueAudit((
            bridge.supervision.ResidueEntry(
                key, bridge.supervision.ProcessRole.LOCAL_DEBUGSERVER,
                bridge.supervision.InspectionState.GONE, True),
        ), True)
        context = object.__new__(bridge._Context)
        context.closed = False
        context.adapter_receipts = {}
        context.descendant_receipts = {}
        context.supervisor = types.SimpleNamespace(
            cleanup_all=lambda: (receipt,), audit_residue=lambda: residue)

        context.cleanup()

        reconciled = context.cleanup_receipts[0]
        self.assertTrue(reconciled.complete)
        self.assertIs(reconciled.final_state, bridge.supervision.InspectionState.GONE)
        self.assertIn("final residue audit proved absence", reconciled.detail)

    def test_context_cleanup_does_not_reconcile_without_ancestor_authority(self):
        key = bridge.supervision.ProcessKey(42, 1, 2, 3, 4)
        receipt = bridge.supervision.CleanupReceipt(
            key, bridge.supervision.ProcessRole.LOCAL_DEBUGSERVER, "owner", 1,
            bridge.supervision.InspectionState.EXACT, "noGracefulAction", False,
            bridge.supervision.InspectionState.EXACT, True, True,
            bridge.supervision.InspectionState.UNSTABLE, False, "", "race",
            object(), True, True, object(), False)
        residue = bridge.supervision.ResidueAudit((
            bridge.supervision.ResidueEntry(
                key, bridge.supervision.ProcessRole.LOCAL_DEBUGSERVER,
                bridge.supervision.InspectionState.GONE, True),), True)
        context = object.__new__(bridge._Context)
        context.closed = False
        context.adapter_receipts = {}
        context.descendant_receipts = {}
        context.supervisor = types.SimpleNamespace(
            cleanup_all=lambda: (receipt,), audit_residue=lambda: residue)

        context.cleanup()

        self.assertFalse(context.cleanup_receipts[0].complete)

    def test_already_gone_cleanup_projection_remains_truthfully_not_revalidated(self):
        registration = types.SimpleNamespace(identity=types.SimpleNamespace(
            pid=7, start_seconds=1, start_microseconds=2,
            real_uid=501, effective_uid=501, canonical_path="/tmp/target",
            cpu_type=0x0100000C, cpu_subtype=0,
            executable_identity="sha256:" + "a" * 64, nonce="N",
            role=bridge.supervision.ProcessRole.LAUNCHED_TARGET,
            executable_device=1, executable_inode=2,
            macho_uuid="12345678-1234-1234-1234-123456789ABC"))
        receipt = types.SimpleNamespace(
            role=bridge.supervision.ProcessRole.LAUNCHED_TARGET,
            pre_action_state=bridge.supervision.InspectionState.GONE,
            observed_identity=registration.identity,
            identity_revalidated=False,
            stable_exact_descendant_chain=False,
            ownership_ancestor_identity=None,
            ownership_ancestor_revalidated=False,
            graceful_action="alreadyGone", term_sent=False,
            final_state=bridge.supervision.InspectionState.GONE,
            complete=True, detail="terminal protocol evidence already observed",
        )
        projected = bridge._cleanup_projection(receipt, {
            bridge.supervision.ProcessRole.LAUNCHED_TARGET: registration,
        })
        self.assertFalse(projected["revalidated"])
        self.assertEqual(projected["action"], "alreadyExited")
        self.assertEqual(projected["terminalState"], "gone")
        self.assertTrue(projected["complete"])

    def test_cleanup_projection_uses_receipt_observation_not_registered_expectation(self):
        expected = types.SimpleNamespace(
            pid=7, start_seconds=1, start_microseconds=2,
            real_uid=501, effective_uid=501, canonical_path="/tmp/expected",
            cpu_type=0x0100000C, cpu_subtype=0,
            executable_identity="sha256:" + "a" * 64, nonce="expected",
            role=bridge.supervision.ProcessRole.ADAPTER,
            executable_device=1, executable_inode=2,
            macho_uuid="12345678-1234-1234-1234-123456789ABC")
        observed = types.SimpleNamespace(
            pid=8, start_seconds=3, start_microseconds=4,
            real_uid=501, effective_uid=501, canonical_path="/tmp/observed",
            cpu_type=0x0100000C, cpu_subtype=0,
            executable_identity="sha256:" + "b" * 64, nonce="observed",
            role=bridge.supervision.ProcessRole.ADAPTER,
            executable_device=3, executable_inode=4,
            macho_uuid="87654321-4321-4321-4321-CBA987654321")
        registration = types.SimpleNamespace(identity=expected)
        receipt = types.SimpleNamespace(
            role=bridge.supervision.ProcessRole.ADAPTER,
            observed_identity=observed,
            identity_revalidated=False,
            stable_exact_descendant_chain=False,
            ownership_ancestor_identity=None,
            ownership_ancestor_revalidated=False,
            pre_action_state=bridge.supervision.InspectionState.IDENTITY_MISMATCH,
            graceful_action="refused", term_sent=False,
            final_state=bridge.supervision.InspectionState.IDENTITY_MISMATCH,
            complete=False, detail="refused immutable identity mismatch",
        )

        projected = bridge._cleanup_projection(receipt, {
            bridge.supervision.ProcessRole.ADAPTER: registration,
        })

        self.assertEqual(projected["expectedIdentity"]["pid"], 7)
        self.assertEqual(projected["observedIdentity"]["pid"], 8)
        self.assertFalse(projected["revalidated"])

    def test_cleanup_projection_uses_explicit_debugserver_ownership_proof(self):
        adapter_identity = types.SimpleNamespace(
            pid=7, start_seconds=1, start_microseconds=2,
            real_uid=501, effective_uid=501, canonical_path="/tmp/adapter",
            cpu_type=0x0100000C, cpu_subtype=0,
            executable_identity="sha256:" + "a" * 64, nonce="adapter",
            role=bridge.supervision.ProcessRole.ADAPTER,
            executable_device=1, executable_inode=2,
            macho_uuid="12345678-1234-1234-1234-123456789ABC")
        debugserver_identity = types.SimpleNamespace(
            pid=8, start_seconds=3, start_microseconds=4,
            real_uid=501, effective_uid=501, canonical_path="/tmp/debugserver",
            cpu_type=0x0100000C, cpu_subtype=0,
            executable_identity="sha256:" + "b" * 64, nonce="debugserver",
            role=bridge.supervision.ProcessRole.LOCAL_DEBUGSERVER,
            executable_device=3, executable_inode=4,
            macho_uuid="87654321-4321-4321-4321-CBA987654321")
        adapter = types.SimpleNamespace(identity=adapter_identity)
        debugserver = types.SimpleNamespace(
            identity=debugserver_identity, parent_key="adapter-key")
        receipt = types.SimpleNamespace(
            role=bridge.supervision.ProcessRole.LOCAL_DEBUGSERVER,
            observed_identity=debugserver_identity,
            identity_revalidated=True,
            stable_exact_descendant_chain=False,
            ownership_ancestor_identity=None,
            ownership_ancestor_revalidated=False,
            pre_action_state=bridge.supervision.InspectionState.EXACT,
            graceful_action="alreadyGone", term_sent=False,
            final_state=bridge.supervision.InspectionState.GONE,
            complete=False, detail="ownership proof unavailable",
        )

        projected = bridge._cleanup_projection(receipt, {
            bridge.supervision.ProcessRole.ADAPTER: adapter,
            bridge.supervision.ProcessRole.LOCAL_DEBUGSERVER: debugserver,
        })

        self.assertEqual(projected["ownershipEvidence"], {
            "stableExactDescendantChain": False,
            "adapterIdentityRevalidated": False,
            "ancestorIdentity": None,
        })


class HookSurfaceTests(unittest.TestCase):
    def test_module_exposes_factory_without_global_runtime_singleton(self):
        self.assertTrue(callable(bridge.make_run_context))
        self.assertFalse(hasattr(bridge, "_runtime"))
        self.assertFalse(hasattr(bridge, "_default_runtime"))

    def test_no_broad_name_or_group_signal_api(self):
        self.assertFalse(hasattr(bridge, "killall"))
        self.assertFalse(hasattr(bridge, "signal_process_group"))

    def test_runtime_fact_has_no_protocol_revision_authority(self):
        fact = bridge.RuntimeProcessFact("attach", 42, True, "exact", {"pid": 42})
        self.assertFalse(hasattr(fact, "requestSequence"))
        self.assertFalse(hasattr(fact, "sessionEpoch"))
        self.assertFalse(hasattr(fact, "lifecycleRevision"))
        self.assertFalse(hasattr(fact, "stopRevision"))

    def test_attach_configuration_does_not_eagerly_register_helper_in_every_candidate(self):
        runtime = bridge.WS18RuntimeBridge(
            process_api=object(), macho_reader=object(), signing_reader=object())
        runtime.attach_target(42, "/tmp/helper", "N", "sha256:" + "0" * 64)
        self.assertEqual(runtime.dap_target_context.registry.registrations, ())
        self.assertEqual(runtime.cli_target_context.registry.registrations, ())
        self.assertEqual(runtime.python_target_context.registry.registrations, ())
        self.assertEqual(runtime.attached_target_context.registry.registrations, ())

    def test_supervisor_context_refuses_snapshot_before_cleanup(self):
        context = object.__new__(bridge._Context)
        context.registry = types.SimpleNamespace(registrations=(object(),))
        context.cleanup_receipts = ()
        context.closed = False
        with self.assertRaisesRegex(bridge.RuntimeBridgeError, "before candidate cleanup"):
            context.report()

    def test_supervisor_context_reports_bounded_cleanup_failure_details(self):
        receipt = types.SimpleNamespace(
            process_key="helper-key",
            role=bridge.supervision.ProcessRole.ATTACHED_HELPER,
            complete=False,
            identity_revalidated=True,
            stable_exact_descendant_chain=False,
            ownership_ancestor_revalidated=False,
            after_graceful_state=bridge.supervision.InspectionState.EXACT,
            detail="x" * (bridge.supervision.MAX_DETAIL_BYTES + 100),
            final_state=bridge.supervision.InspectionState.EXACT,
            graceful_acknowledged=True,
            graceful_action="fixtureExit",
            pre_action_state=bridge.supervision.InspectionState.EXACT,
            term_attempted=False,
            term_sent=False,
        )
        residue_entry = types.SimpleNamespace(
            role=bridge.supervision.ProcessRole.ATTACHED_HELPER,
            state=bridge.supervision.InspectionState.EXACT,
            absent=False,
            detail="still inspectable",
        )
        context = object.__new__(bridge._Context)
        context.registry = types.SimpleNamespace(registrations=(object(),))
        context.cleanup_receipts = (receipt,)
        context.residue = types.SimpleNamespace(
            entries=(residue_entry,), complete=False)
        context.closed = True

        with mock.patch.object(
                bridge.supervision, "cleanup_receipts_are_complete",
                return_value=False), self.assertRaises(bridge.RuntimeBridgeError) as caught:
            context.report()

        prefix = "supervisor cleanup or residue evidence is incomplete: "
        self.assertTrue(str(caught.exception).startswith(prefix))
        diagnostic = json.loads(str(caught.exception)[len(prefix):])
        self.assertFalse(diagnostic["receiptsComplete"])
        self.assertFalse(diagnostic["residueComplete"])
        self.assertEqual(diagnostic["receipts"][0]["role"], "helper")
        self.assertEqual(diagnostic["receipts"][0]["finalState"], "exact")
        self.assertLessEqual(
            len(diagnostic["receipts"][0]["detail"]),
            bridge.supervision.MAX_DETAIL_BYTES,
        )
        self.assertEqual(diagnostic["residue"][0], {
            "absent": False,
            "detail": "still inspectable",
            "role": "helper",
            "state": "exact",
        })

    def test_report_identity_projection_matches_frozen_schema_and_keeps_signer_separate(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "helper"; path.write_bytes(b"fixture")
            projected = bridge._identity_projection(identity(
                42, path, bridge.supervision.ProcessRole.ATTACHED_HELPER))
        self.assertEqual(projected["role"], "helper")
        self.assertEqual(set(projected), {
            "pid", "startTimeNS", "realUID", "effectiveUID", "canonicalPath",
            "cpuType", "cpuSubtype", "executableIdentity", "nonce", "role",
            "device", "inode", "machOUUID",
        })
        self.assertNotIn("signingIdentity", projected)

    def test_report_identity_projection_canonicalizes_cpu_subtype_capability_bits(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "debugserver"; path.write_bytes(b"fixture")
            exact = replace(identity(
                42, path, bridge.supervision.ProcessRole.LOCAL_DEBUGSERVER),
                cpu_subtype=-2130706430,
            )

            projected = bridge._identity_projection(exact)

        self.assertEqual(projected["cpuSubtype"], 0x81000002)


def run_arguments(root: Path, *, mode: str = "launch"):
    executable = root / ("main" if mode == "launch" else "helper")
    executable.write_bytes(b"fixture")
    control = root / ("control-" + mode)
    control.mkdir(mode=0o700, exist_ok=True)
    common = dict(
        command=mode,
        control_dir=control,
        nonce="N",
        executable_identity="sha256:" + hashlib.sha256(b"fixture").hexdigest(),
        macho_uuid="12345678-1234-1234-1234-123456789ABC",
        signing_identity=bridge.APPROVED_FIXTURE_SIGNER,
        started_after_ns=control.stat().st_mtime_ns,
    )
    if mode == "launch":
        common["executable"] = executable
    else:
        common["helper"] = executable
    return bridge.argparse.Namespace(**common)


class RunContextFactoryTests(unittest.TestCase):
    def make_context(self, candidate, mode, arguments, **kwargs):
        return bridge.WS18RunContext(candidate, mode, arguments,
            process_api=object(), macho_reader=object(), signing_reader=object(),
            **kwargs)

    def test_each_factory_context_has_one_registry_shared_by_its_lifecycle(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            arguments = run_arguments(root)
            for candidate, expected_type in (
                ("xcode-lldb-dap", bridge._DAPLifecycle),
                ("xcode-lldb-python-json", bridge._PythonLifecycle),
                ("macscope-lldb-cli-baseline", bridge._CLILifecycle),
            ):
                run = self.make_context(candidate, "launch", arguments)
                lifecycle = run.lifecycle()
                self.assertIsInstance(lifecycle, expected_type)
                self.assertIs(lifecycle.context, run.context)
                contexts = [value for value in vars(run).values()
                            if isinstance(value, bridge._Context)]
                self.assertEqual(contexts, [run.context])

    def test_candidate_locked_lifecycle_accessors_share_the_run_registry(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            cases = (
                ("xcode-lldb-dap", "make_dap_lifecycle", bridge._DAPLifecycle),
                ("xcode-lldb-python-json", "make_python_lifecycle", bridge._PythonLifecycle),
                ("macscope-lldb-cli-baseline", "make_cli_lifecycle", bridge._CLILifecycle),
            )
            for candidate, accessor, expected_type in cases:
                run = self.make_context(candidate, "launch", run_arguments(root))
                lifecycle = getattr(run, accessor)()
                self.assertIsInstance(lifecycle, expected_type)
                self.assertIs(lifecycle.context, run.context)
                wrong = next(name for name in (
                    "make_dap_lifecycle", "make_python_lifecycle", "make_cli_lifecycle"
                ) if name != accessor)
                with self.assertRaisesRegex(bridge.RuntimeBridgeError, "belongs to"):
                    getattr(run, wrong)()

    def test_cli_lifecycle_authorizes_only_the_frozen_launch_configuration(self):
        with tempfile.TemporaryDirectory() as directory:
            arguments = run_arguments(Path(directory))
            arguments.argument = ("--nonce", "N")
            arguments.environment = {"MACSCOPE_TEST": "1"}
            run = self.make_context(
                "macscope-lldb-cli-baseline", "launch", arguments)
            lifecycle = run.make_cli_lifecycle()
            executable = str(arguments.executable.resolve())
            cwd = str(arguments.executable.parent.resolve())
            accepted = lifecycle.authorize_launch(
                executable, ("--nonce", "N"), cwd, {"MACSCOPE_TEST": "1"})
            denied = lifecycle.authorize_launch(
                executable, ("--nonce", "wrong"), cwd, {"MACSCOPE_TEST": "1"})

            self.assertTrue(accepted["authorized"])
            self.assertEqual(accepted["launch"]["arguments"], ["--nonce", "N"])
            self.assertFalse(denied["authorized"])

    def test_launch_accepts_parser_sha256_without_weakening_canonical_identity(self):
        with tempfile.TemporaryDirectory() as directory:
            arguments = run_arguments(Path(directory))
            del arguments.executable_identity
            arguments.executable_sha256 = hashlib.sha256(b"fixture").hexdigest()
            run = self.make_context("xcode-lldb-dap", "launch", arguments)
            self.assertEqual(
                run.authorization.executable_identity,
                "sha256:" + hashlib.sha256(b"fixture").hexdigest(),
            )
            arguments.executable_sha256 = "A" * 64
            with self.assertRaisesRegex(bridge.RuntimeBridgeError, "canonical SHA-256"):
                self.make_context("xcode-lldb-dap", "launch", arguments)

    def test_python_authority_is_bound_to_exactly_one_run_mode(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            launch_args = run_arguments(root)
            launch = self.make_context(
                "xcode-lldb-python-json", "launch", launch_args)
            launch_authority = launch.make_python_authority()
            self.assertTrue(launch_authority.authorize_launch(
                str(launch_args.executable.resolve()), [],
                str(launch_args.executable.parent.resolve()), {},
            )["authorized"])
            self.assertFalse(launch_authority.authorize_attach({})["authorized"])

            attach_args = run_arguments(root, mode="attach")
            attach = self.make_context(
                "xcode-lldb-python-json", "attach", attach_args)
            with self.assertRaisesRegex(bridge.RuntimeBridgeError, "prepared"):
                attach.make_python_authority()

    def test_prepare_attach_helper_opens_and_returns_same_live_control_before_ready(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            arguments = run_arguments(root, mode="attach")
            arguments.started_after_ns = 1_000_002_000
            pid = 4242
            process = types.SimpleNamespace(pid=pid, poll=lambda: None)
            calls = []
            controls = []

            class Control:
                def __init__(self, control_dir, role, nonce, target_pid):
                    self.control_dir = control_dir
                    self.role = role
                    self.nonce = nonce
                    self.pid = target_pid
                    self.command_path = control_dir / (role + ".commands")
                    self.opened = False
                    self.closed = False
                    controls.append(self)
                def open(self, timeout=5.0):
                    calls.append(("open", timeout))
                    self.opened = True
                def _events(self):
                    calls.append(("events", self.opened))
                    if not self.opened:
                        raise AssertionError("ready was polled before control opened")
                    return [{"schema": 1, "sequence": 1,
                        "commandSequence": 0, "nonce": self.nonce,
                        "operation": "ready", "pid": self.pid, "result": "ok",
                        "role": self.role}]
                def close(self):
                    calls.append(("close", None))
                    self.closed = True

            def launcher(argv, **options):
                calls.append(("launch", (tuple(argv), dict(options))))
                os.mkfifo(arguments.control_dir / "helper.commands", 0o600)
                return process

            run = self.make_context("xcode-lldb-dap", "attach", arguments,
                                    fixture_launcher=launcher)
            inspector = FakeInspector()
            exact = identity(pid, arguments.helper,
                bridge.supervision.ProcessRole.ATTACHED_HELPER,
                nonce=arguments.nonce)
            inspector.snapshots[pid] = bridge.supervision.ProcessSnapshot(
                bridge.supervision.InspectionState.EXACT, exact,
                bridge.supervision.ProcessTopology(1, pid, pid))
            run.context.inspector = inspector
            run.context.registry = bridge.supervision.ProcessRegistry(
                run.context.owner, inspector)

            original_client = bridge.drivers.FixtureControlClient
            bridge.drivers.FixtureControlClient = Control
            try:
                target, control = run.prepare_attach_helper()
            finally:
                bridge.drivers.FixtureControlClient = original_client

            self.assertEqual(target.pid, pid)
            self.assertEqual(target.canonicalPath, str(arguments.helper.resolve()))
            self.assertEqual(target.executableIdentity, arguments.executable_identity)
            self.assertIs(control, controls[0])
            self.assertTrue(control.opened)
            self.assertFalse(control.closed)
            self.assertEqual(calls[0][0], "launch")
            self.assertEqual(calls[0][1][0][0], str(arguments.helper.resolve()))
            self.assertTrue(calls[0][1][1]["start_new_session"])
            self.assertEqual(calls[1:], [("open", 5.0), ("events", True)])
            with self.assertRaisesRegex(bridge.RuntimeBridgeError, "already prepared"):
                run.prepare_attach_helper()

    def test_prepare_attach_helper_closes_control_then_context_when_open_fails(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            arguments = run_arguments(root, mode="attach")
            arguments.started_after_ns = 1_000_002_000
            pid = 4242
            process = types.SimpleNamespace(pid=pid, poll=lambda: None)
            order = []

            class Control:
                def __init__(self, control_dir, role, nonce, target_pid): pass
                def open(self, timeout=5.0):
                    order.append("open")
                    raise TimeoutError("fixture command FIFO open timed out")
                def close(self): order.append("control-close")

            def launcher(argv, **options):
                os.mkfifo(arguments.control_dir / "helper.commands", 0o600)
                return process

            run = self.make_context("xcode-lldb-dap", "attach", arguments,
                                    fixture_launcher=launcher)
            inspector = FakeInspector()
            exact = identity(pid, arguments.helper,
                bridge.supervision.ProcessRole.ATTACHED_HELPER,
                nonce=arguments.nonce)
            inspector.snapshots[pid] = bridge.supervision.ProcessSnapshot(
                bridge.supervision.InspectionState.EXACT, exact,
                bridge.supervision.ProcessTopology(1, pid, pid))
            run.context.inspector = inspector
            run.context.registry = bridge.supervision.ProcessRegistry(
                run.context.owner, inspector)
            run.close = lambda: order.append("context-close")

            original_client = bridge.drivers.FixtureControlClient
            bridge.drivers.FixtureControlClient = Control
            try:
                with self.assertRaisesRegex(TimeoutError, "FIFO open timed out"):
                    run.prepare_attach_helper()
            finally:
                bridge.drivers.FixtureControlClient = original_client

            self.assertEqual(order, ["open", "control-close", "context-close"])

    def test_invalid_candidate_mode_or_identity_fails_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            arguments = run_arguments(root)
            with self.assertRaisesRegex(bridge.RuntimeBridgeError, "unknown WS-18 candidate"):
                self.make_context("unknown", "launch", arguments)
            with self.assertRaisesRegex(bridge.RuntimeBridgeError, "unknown WS-18 run mode"):
                self.make_context("xcode-lldb-dap", "remote", arguments)
            arguments.executable_identity = "not-a-digest"
            with self.assertRaisesRegex(bridge.RuntimeBridgeError, "canonical SHA-256"):
                self.make_context("xcode-lldb-dap", "launch", arguments)

    def test_mode_mismatch_and_unapproved_signer_fail_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            arguments = run_arguments(root)
            with self.assertRaisesRegex(bridge.RuntimeBridgeError, "disagrees"):
                self.make_context("xcode-lldb-dap", "attach", arguments)
            arguments.signing_identity = "Apple Development: Other (AAAAAAAAAA)"
            with self.assertRaisesRegex(bridge.RuntimeBridgeError, "not approved"):
                self.make_context("xcode-lldb-dap", "launch", arguments)

    def test_close_precedes_candidate_mode_attributed_snapshot(self):
        with tempfile.TemporaryDirectory() as directory:
            run = self.make_context(
                "xcode-lldb-dap", "launch", run_arguments(Path(directory)))
            with self.assertRaisesRegex(bridge.RuntimeBridgeError, "must close"):
                run.supervisor_snapshot()
            run.close()
            snapshot = run.supervisor_snapshot()
            self.assertIs(snapshot["cleanupComplete"], True)
            self.assertEqual(snapshot["candidate"], "xcode-lldb-dap")
            self.assertEqual(snapshot["mode"], "launch")
            self.assertTrue(snapshot["closed"])
            self.assertEqual(snapshot["processRegistry"], [])

    def test_snapshot_never_publishes_cleanup_complete_when_report_rejects_evidence(self):
        run = object.__new__(bridge.WS18RunContext)
        run._closed = True
        run.context = types.SimpleNamespace(
            report=lambda: (_ for _ in ()).throw(
                bridge.RuntimeBridgeError(
                    "supervisor cleanup or residue evidence is incomplete")),
        )

        with self.assertRaisesRegex(bridge.RuntimeBridgeError, "evidence is incomplete"):
            run.supervisor_snapshot()

    def test_closed_context_rejects_lifecycle_and_process_observation(self):
        with tempfile.TemporaryDirectory() as directory:
            run = self.make_context(
                "xcode-lldb-dap", "launch", run_arguments(Path(directory)))
            run.close()
            with self.assertRaisesRegex(bridge.RuntimeBridgeError, "no lifecycle"):
                run.lifecycle()
            with self.assertRaisesRegex(bridge.RuntimeBridgeError, "cannot observe"):
                run.observe_process(42)

    def test_process_observation_returns_after_exact_target_admission(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "main"
            path.write_bytes(b"fixture")
            target = identity(
                42, path, bridge.supervision.ProcessRole.LAUNCHED_TARGET)
            registration = types.SimpleNamespace(identity=target)
            descendant_calls = []
            context = types.SimpleNamespace(
                ensure_target=lambda *args: registration,
                exact=lambda pid: True,
                observe_debugger_descendants=lambda: descendant_calls.append(pid),
            )
            pid = target.pid
            run = object.__new__(bridge.WS18RunContext)
            run._closed = False
            run.authorization = types.SimpleNamespace(
                path=target.canonical_path,
                nonce=target.nonce,
                attached=False,
                executable_identity=target.executable_identity,
                macho_uuid=target.macho_uuid,
                signing_identity=target.signing_identity,
            )
            run.context = context
            run._attach_target = None
            run._last_fact = None
            run.mode = "launch"
            run._admit_launch_target = lambda observed_pid: registration

            fact = run.observe_process(pid, "launch")

            self.assertTrue(fact.identityMatched)
            self.assertEqual(descendant_calls, [])


if __name__ == "__main__":
    unittest.main()
