#!/usr/bin/env python3

from __future__ import annotations

import importlib.util
import hashlib
import json
import os
import sys
import tempfile
import unittest
import copy
from contextlib import contextmanager
from dataclasses import dataclass
from pathlib import Path
from types import SimpleNamespace
from unittest import mock


ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "Scripts" / "debugger-fixture" / "transport_probe.py"
spec = importlib.util.spec_from_file_location("transport_probe", SOURCE)
assert spec and spec.loader
probe = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = probe
spec.loader.exec_module(probe)


class ModuleWiringTests(unittest.TestCase):
    def test_matrix_signal_boundary_raises_once_and_restores_handlers(self):
        installed = {
            probe.signal.SIGINT: "old-int",
            probe.signal.SIGTERM: "old-term",
        }

        def install(signum, handler):
            previous = installed[signum]
            installed[signum] = handler
            return previous

        with mock.patch.object(probe.signal, "signal", side_effect=install):
            boundary = probe._MatrixSignalBoundary()
            with self.assertRaises(probe.MatrixSignalInterrupt) as caught:
                with boundary:
                    handler = installed[probe.signal.SIGTERM]
                    handler(probe.signal.SIGTERM, None)

            self.assertEqual(caught.exception.exit_code, 128 + probe.signal.SIGTERM)
            self.assertIsNone(handler(probe.signal.SIGINT, None))
            self.assertEqual(installed[probe.signal.SIGINT], "old-int")
            self.assertEqual(installed[probe.signal.SIGTERM], "old-term")

    def test_transport_and_supervisor_exports_are_the_real_sibling_owners(self):
        self.assertIs(probe.DAPFrameParser, probe.dap.DAPFrameParser)
        self.assertIs(probe.DAPSession, probe.dap.DAPSession)
        self.assertIs(probe.ABASnapshotInspector, probe.supervisor.ABASnapshotInspector)
        self.assertIs(probe.OuterSupervisor, probe.supervisor.OuterProcessSupervisor)

    def test_exact_helper_conversion_rejects_authorization_drift_before_registry(self):
        target = probe.drivers.ExactAttachTarget(42, 1_000_000_002, 501, 501,
            "/tmp/helper", 0x0100000C, 0, "exec", 1, 2,
            "12345678-1234-1234-1234-123456789ABC", "signer", "N")
        identity = probe.supervisor.ImmutableProcessIdentity(42, 1, 2, "/tmp/other", 1, 2,
            501, 501, 0, 0, "UUID", "signer", "N",
            probe.supervisor.ProcessRole.ATTACHED_HELPER)
        class Registry:
            def register(self, value): raise AssertionError("must not register mismatch")
        with self.assertRaisesRegex(probe.ProbeError, "differs"):
            probe.register_exact_helper(target, identity, Registry())

    def test_runtime_bridge_requires_every_supervision_hook(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "bridge.py"
            path.write_text("def make_dap_lifecycle(): pass\n")
            with self.assertRaisesRegex(probe.ProbeError, "supervision contract"):
                probe._load_runtime_bridge(path)

    def test_runtime_bridge_loader_registers_module_before_dataclass_execution(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "bridge.py"
            path.write_text(
                "from dataclasses import dataclass\n"
                "@dataclass(frozen=True)\n"
                "class BridgeFact:\n"
                "    value: int\n"
                "def make_run_context(candidate, mode, arguments):\n"
                "    return BridgeFact(1)\n"
            )
            module = probe._load_runtime_bridge(path)
        self.assertEqual(module.BridgeFact(7).value, 7)

    def test_legacy_discover_constructs_runner_only_python_driver_and_dispatches(self):
        coordinator = mock.Mock()
        with tempfile.TemporaryDirectory() as directory, \
                mock.patch.object(probe.drivers, "LldbDAPDriver", autospec=True), \
                mock.patch.object(probe.drivers, "LldbPythonJSONDriver", autospec=True) as python, \
                mock.patch.object(probe.drivers, "LldbCLIDriver", autospec=True), \
                mock.patch.object(probe, "ProbeCoordinator", return_value=coordinator):
            result = probe.main([
                "--artifact-root", directory,
                "discover",
            ])

        self.assertEqual(result, 0)
        python.assert_called_once()
        self.assertEqual(len(python.call_args.args), 1)
        self.assertEqual(python.call_args.kwargs, {})
        coordinator.discovery.assert_called_once_with()
        coordinator.close.assert_called_once_with()

    def test_matrix_parser_requires_verified_fixture_freshness_and_control_authority(self):
        parser = probe._argument_parser()
        with self.assertRaises(SystemExit):
            parser.parse_args(["--artifact-root", "/tmp/ws18", "matrix",
                               "--executable", "/tmp/fixture"])
        parsed = parser.parse_args([
            "--artifact-root", "/tmp/ws18", "--runtime-bridge", "/tmp/bridge.py",
            "matrix", "--executable", "/tmp/fixture",
            "--executable-sha256", "a" * 64,
            "--macho-uuid", "12345678-1234-1234-1234-123456789ABC",
            "--signing-identity", "signer", "--started-after-ns", "1",
            "--helper", "/tmp/helper", "--helper-sha256", "b" * 64,
            "--helper-macho-uuid", "ABCDEFAB-1234-1234-1234-123456789ABC",
            "--helper-signing-identity", "signer",
            "--nonce", "nonce", "--control-root", "/tmp/control",
            "--toolchain-context", "/tmp/toolchain.json",
            "--fixture-context", "/tmp/fixture.json", "--output", "/tmp/report.json",
        ])
        self.assertEqual(parsed.command, "matrix")
        self.assertEqual(parsed.executable_sha256, "a" * 64)
        self.assertEqual(parsed.control_root, Path("/tmp/control"))

    def test_obsolete_standalone_live_commands_are_not_exposed(self):
        parser = probe._argument_parser()
        commands = next(
            action.choices for action in parser._actions
            if isinstance(action, probe.argparse._SubParsersAction)
        )
        self.assertNotIn("launch", commands)
        self.assertNotIn("attach", commands)

    def test_matrix_cells_use_distinct_app_and_helper_authority(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            root.chmod(0o700)
            base = {
                "control_root": str(root), "started_after_ns": 1,
                "nonce_seed": "matrix", "executable": "/tmp/app",
                "helper": "/tmp/helper", "executable_identity": "sha256:" + "a" * 64,
                "helper_executable_identity": "sha256:" + "b" * 64,
                "macho_uuid": "12345678-1234-1234-1234-123456789ABC",
                "helper_macho_uuid": "ABCDEFAB-1234-1234-1234-123456789ABC",
                "signing_identity": "app signer", "helper_signing_identity": "helper signer",
                "argument": ("--user-option",),
            }
            launch = probe._fresh_cell_arguments(base, "xcode-lldb-dap", "launch")
            attach = probe._fresh_cell_arguments(base, "xcode-lldb-dap", "attach")
        self.assertEqual(launch["executable_identity"], "sha256:" + "a" * 64)
        self.assertEqual(attach["helper"], "/tmp/helper")
        self.assertEqual(attach["executable_identity"], "sha256:" + "b" * 64)
        self.assertEqual(attach["macho_uuid"], base["helper_macho_uuid"])
        self.assertEqual(attach["signing_identity"], "helper signer")
        self.assertIn("--user-option", launch["argument"])
        self.assertNotIn("--user-option", attach["argument"])


class JournalTests(unittest.TestCase):
    def test_journal_is_append_only_sequence_bounded_and_mode_0600(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "raw.jsonl"
            journal = probe.RawJournal(path, max_bytes=1000)
            journal.append("one", {"value": 1})
            journal.append("two", {"value": 2})
            records = [json.loads(line) for line in path.read_text().splitlines()]
            self.assertEqual([row["sequence"] for row in records], [1, 2])
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)

    def test_journal_refuses_oversized_evidence(self):
        with tempfile.TemporaryDirectory() as directory:
            journal = probe.RawJournal(Path(directory) / "raw.jsonl", max_bytes=40)
            with self.assertRaisesRegex(probe.ProbeError, "bound"):
                journal.append("large", {"value": "x" * 100})

    def test_aggregate_revalidates_source_sequences_and_preserves_source_digest(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            first = probe.RawJournal(root / "one.jsonl")
            second = probe.RawJournal(root / "two.jsonl")
            first.append("one", {"value": 1})
            second.append("two", {"value": 2})
            output = root / "aggregate.jsonl"
            self.assertEqual(probe.aggregate_raw_journals((first.path, second.path), output), 2)
            records = [json.loads(line) for line in output.read_text().splitlines()]
            self.assertEqual([row["sequence"] for row in records], [1, 2])
            self.assertEqual(len(records[0]["payload"]["sourceSHA256"]), 64)

    def test_journal_rejects_stale_symlink_and_out_of_root_outputs(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            stale = root / "stale.jsonl"
            stale.write_text("old evidence\n")
            with self.assertRaisesRegex(probe.ProbeError, "stale"):
                probe.RawJournal(stale, artifact_root=root)

            target = root / "target.jsonl"
            target.write_text("")
            link = root / "link.jsonl"
            link.symlink_to(target)
            with self.assertRaisesRegex(probe.ProbeError, "symlink"):
                probe.RawJournal(link, artifact_root=root)

            outside = root.parent / (root.name + "-outside.jsonl")
            try:
                with self.assertRaisesRegex(probe.ProbeError, "artifact root"):
                    probe.RawJournal(outside, artifact_root=root)
            finally:
                outside.unlink(missing_ok=True)

    def test_journal_holds_secure_regular_0600_file_and_close_is_terminal(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            root.chmod(0o700)
            journal = probe.RawJournal(root / "raw.jsonl", artifact_root=root)
            journal.append("one", {"value": 1})
            self.assertEqual(journal.path.stat().st_mode & 0o777, 0o600)
            self.assertEqual(journal.path.stat().st_uid, os.geteuid())
            journal.close()
            with self.assertRaisesRegex(probe.ProbeError, "closed"):
                journal.append("two", {"value": 2})

    def test_aggregate_rejects_mixed_scope_and_symlink_sources(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = probe.RawJournal(root / "source.jsonl", artifact_root=root,
                                      journal_id="scope-A")
            source.append("one", {"value": 1})
            source.close()
            records = [json.loads(line) for line in source.path.read_text().splitlines()]
            records.append({**records[0], "sequence": 2, "journalID": "scope-B"})
            source.path.write_text("\n".join(json.dumps(row) for row in records) + "\n")
            source.path.chmod(0o600)
            with self.assertRaisesRegex(probe.ProbeError, "mixed"):
                probe.aggregate_raw_journals((source.path,), root / "output.jsonl",
                                             artifact_root=root)

            clean = probe.RawJournal(root / "clean.jsonl", artifact_root=root)
            clean.append("one", {"value": 1})
            clean.close()
            link = root / "source-link.jsonl"
            link.symlink_to(clean.path)
            with self.assertRaisesRegex(probe.ProbeError, "symlink"):
                probe.aggregate_raw_journals((link,), root / "linked-output.jsonl",
                                             artifact_root=root)


@dataclass(frozen=True)
class Provenance:
    path: str = "/Xcode/tool"
    version: str = "27"
    sha256: str = "a" * 64
    signing: dict = None

    def __post_init__(self):
        object.__setattr__(self, "signing", self.signing or {})


class FakeDriver:
    def __init__(self, candidate): self.candidate = candidate
    def provenance(self): return Provenance()
    def launch(self, request, executable, arguments, cwd, environment):
        return probe.drivers.CandidateOperationEvidence(self.candidate, "launch", "observed",
            request, 42, "running", {"processId": 42})
    def attach(self, request, pid):
        return probe.drivers.CandidateOperationEvidence(self.candidate, "attach", "observed",
            request, pid, "running", {"processId": pid})
    def detach(self, request, pid, control):
        return probe.drivers.CandidateOperationEvidence(self.candidate, "detach", "observed",
            request, pid, "detached", {"postDetachControl": control.send("checkpoint")})

    def close(self): return None


class PythonDriver:
    def discover(self):
        return probe.drivers.PythonLLDBDiscovery(False, None, None, None,
                                                 {"reason": "unsupported"})


class PythonValidatorEvidenceProjectionTests(unittest.TestCase):
    @staticmethod
    def _protocol(result):
        return {
            "requestID": "run:detach", "sessionID": "session",
            "sessionEpoch": 1, "lifecycleRevision": 2, "stopRevision": 1,
            "sequence": 3, "result": result, "evidence": {},
        }

    def test_detach_projects_exact_post_detach_pid_when_target_pid_is_absent(self):
        observed = []
        context = SimpleNamespace(
            observe_process=lambda pid, operation: observed.append((pid, operation)) or {},
        )

        projection = probe._project_python_validator_evidence(
            context, "detach", self._protocol({"postDetach": {"pid": 42}}),
        )

        self.assertEqual(observed, [(42, "detach")])
        self.assertEqual(
            projection["validatorEvidence"]["postcondition"]["operation"], "detach",
        )

    def test_detach_rejects_mismatched_target_and_post_detach_pids(self):
        context = SimpleNamespace(
            observe_process=lambda pid, operation: self.fail("must reject before observation"),
        )

        with self.assertRaisesRegex(probe.ProbeError, "detach PID fields disagree"):
            probe._project_python_validator_evidence(
                context, "detach",
                self._protocol({"targetPID": 41, "postDetach": {"pid": 42}}),
            )

    def test_detach_rejects_missing_or_invalid_post_detach_pid(self):
        context = SimpleNamespace(
            observe_process=lambda pid, operation: self.fail("must reject before observation"),
        )

        for result in (
            {}, {"targetPID": 42}, {"postDetach": {}}, {"postDetach": {"pid": 0}},
            {"postDetach": {"pid": True}}, {"postDetach": {"pid": "42"}},
            {"targetPID": 0, "postDetach": {"pid": 42}},
            {"targetPID": True, "postDetach": {"pid": 42}},
        ):
            with self.subTest(result=result):
                with self.assertRaisesRegex(
                    probe.ProbeError, "Python detach response lacks exact target identity",
                ):
                    probe._project_python_validator_evidence(
                        context, "detach", self._protocol(result),
                    )

    def test_non_detach_operation_still_requires_positive_target_pid(self):
        context = SimpleNamespace(
            observe_process=lambda pid, operation: self.fail("must reject before observation"),
        )

        with self.assertRaisesRegex(
            probe.ProbeError, "Python protocol response lacks request/target identity",
        ):
            probe._project_python_validator_evidence(
                context, "attach", self._protocol({"postDetach": {"pid": 42}}),
            )


class CoordinatorTests(unittest.TestCase):
    def test_launch_admission_verifies_bytes_freshness_and_injects_control_contract_once(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            executable = root / "fixture"
            executable.write_bytes(b"signed fixture bytes")
            executable.chmod(0o700)
            control = root / "control"
            control.mkdir(mode=0o700)
            now = 9_000_000_000
            digest = hashlib.sha256(executable.read_bytes()).hexdigest()
            accepted = probe.accepted_launch_identity(
                executable, executable_sha256=digest,
                macho_uuid="12345678-1234-1234-1234-123456789ABC",
                signing_identity="Apple Development: Test", nonce="fresh-nonce",
                started_after_ns=now - 1, control_directory=control,
                user_arguments=("--fixture-user-option", "value"), now_ns=now,
            )
            self.assertEqual(accepted.executableIdentity, "sha256:" + digest)
            self.assertEqual(accepted.fixtureArguments.count("--control-dir"), 1)
            self.assertEqual(accepted.fixtureArguments.count("--nonce"), 1)
            self.assertEqual(accepted.fixtureArguments.count("--started-after-ns"), 1)
            with self.assertRaisesRegex(probe.ProbeError, "SHA-256 does not match"):
                probe.accepted_launch_identity(
                    executable, executable_sha256="0" * 64,
                    macho_uuid=accepted.machOUUID,
                    signing_identity=accepted.signingIdentity, nonce=accepted.nonce,
                    started_after_ns=now, control_directory=control,
                    user_arguments=(), now_ns=now,
                )
            with self.assertRaisesRegex(probe.ProbeError, "cannot be supplied twice"):
                probe.accepted_launch_identity(
                    executable, executable_sha256=digest,
                    macho_uuid=accepted.machOUUID,
                    signing_identity=accepted.signingIdentity, nonce=accepted.nonce,
                    started_after_ns=now, control_directory=control,
                    user_arguments=("--nonce=forged",), now_ns=now,
                )

    def test_complete_matrix_aliases_launch_without_fabricating_missing_observations(self):
        item = probe.drivers.CandidateOperationEvidence(
            "xcode-lldb-dap", "launch", "observed", "R", 41, "running",
            {"protocol": "fact"},
        )
        matrix = probe.complete_operation_matrix("xcode-lldb-dap", "run", (item,))
        self.assertEqual([value.operation for value in matrix], list(probe.schema.OPERATION_ORDER))
        self.assertEqual(matrix[0].observation, "observed")
        self.assertTrue(all(value.observation == "notAttempted" for value in matrix[1:]))

    def test_persistent_cli_matrix_adapter_exposes_launch_and_frozen_operations(self):
        calls = []
        class Session:
            def execute_operation(self, operation, request, arguments):
                calls.append((operation, request, arguments)); return operation
            def attach_and_detach(self, **arguments):
                calls.append(("attach_and_detach", arguments))
                return arguments
            def close(self): return {"complete": True}
        driver = probe._PersistentCLIMatrixDriver(Session())
        self.assertEqual(driver.launch("L", Path("/tmp/f"), ("a",), Path("/tmp"), {}),
                         "configuredLaunch")
        self.assertEqual(driver.exercise_operation("R", "launchWorkingDirectory", {
            "workingDirectory": "/tmp", "operationArguments": {},
        }), "launchWorkingDirectory")
        self.assertEqual(calls[0][0], "configuredLaunch")
        self.assertEqual(calls[1][2]["workingDirectory"], "/tmp")
        checkpoint = lambda pid: {"pid": pid}
        self.assertEqual(driver.attach_and_detach(
            pid=42, attach_request_id="A", detach_request_id="D",
            post_detach_probe=checkpoint,
        ), {
            "pid": 42, "attach_request_id": "A", "detach_request_id": "D",
            "post_detach_probe": checkpoint,
        })

    def test_run_projection_closes_candidate_control_and_bridge_before_snapshot(self):
        order = []
        candidate = "xcode-lldb-dap"
        class Driver:
            def attach_and_detach(self, attach_id, detach_id, pid, control):
                return (
                    probe.drivers.CandidateOperationEvidence(candidate, "attach", "protocolError",
                        attach_id, pid, "targetDispositionUnknown", {},
                        {"classification": "protocolError"}),
                    probe.drivers.CandidateOperationEvidence(candidate, "detach", "notAttempted",
                        detach_id, pid, "targetDispositionUnknown", {},
                        {"classification": "notAttempted"}),
                )
            def close(self): order.append("candidate")
        class Control:
            pid, nonce = 42, "N"
            def close(self): order.append("control")
        identity = {
            "pid": 42, "startTimeNS": 1, "realUID": 501, "effectiveUID": 501,
            "canonicalPath": "/tmp/helper", "cpuType": 0x0100000C, "cpuSubtype": 0,
            "executableIdentity": "sha256:" + "a" * 64, "nonce": "N", "role": "helper",
            "device": 1, "inode": 2,
            "machOUUID": "12345678-1234-1234-1234-123456789ABC",
        }
        artifacts = {
            "candidate": candidate, "mode": "attach",
            "processRegistry": [{"role": "helper", "identity": identity}],
            "cleanupReceipts": [{"role": "helper", "complete": True}],
            "residueAudit": {"auditedIdentities": [identity], "remainingIdentities": [],
                "complete": True, "evidence": {}}, "signingEvidence": [],
        }
        class Bridge:
            @contextmanager
            def admission_boundary(self):
                yield
            def revalidate(self, target): return True
            def close(self): order.append("bridge")
            def supervisor_snapshot(self):
                order.append("snapshot")
                return {"cleanupComplete": True, "contexts": [artifacts]}
        target = probe.drivers.ExactAttachTarget(
            42, 1, 501, 501, "/tmp/helper", 0x0100000C, 0,
            "sha256:" + "a" * 64, 1, 2,
            "12345678-1234-1234-1234-123456789ABC", "signer", "N",
        )
        with tempfile.TemporaryDirectory() as directory:
            journal = probe.RawJournal(Path(directory) / "run.jsonl")
            projection = probe.execute_candidate_mode(
                candidate=candidate, candidate_version="v", mode="attach",
                driver=Driver(), bridge=Bridge(), journal=journal,
                attach_target=target, attach_control=Control(),
            )
            records = [json.loads(line) for line in journal.path.read_text().splitlines()]
        self.assertEqual(order, ["candidate", "bridge", "control", "snapshot"])
        self.assertEqual(len(projection.observations), len(probe.schema.OPERATION_ORDER))
        self.assertEqual([row["kind"] for row in records], ["candidate-protocol-facts"])
        self.assertEqual(projection.candidate, candidate)

    def test_launch_process_admission_boundary_spans_request_and_binding(self):
        order = []
        candidate = "xcode-lldb-dap"

        class Driver:
            def launch(self, request, executable, arguments, cwd, environment):
                order.append("launch")
                return probe.drivers.CandidateOperationEvidence(
                    candidate, "launch", "observed", request, 42, "running", {},
                )
            def close(self): order.append("candidate-close")

        class Bridge:
            @contextmanager
            def admission_boundary(self):
                order.append("admission-enter")
                try:
                    yield
                finally:
                    order.append("admission-exit")
            def close(self): order.append("bridge-close")
            def supervisor_snapshot(self):
                return {"cleanupComplete": True, "contexts": []}

        identity = probe.AcceptedLaunchIdentity(
            Path("/tmp/fixture"), "sha256:" + "a" * 64,
            "12345678-1234-1234-1234-123456789ABC", "signer", "N", 1,
            Path("/tmp"), (),
        )
        original = probe._normalize_candidate_evidence
        def normalize(value, context=None):
            order.append("bind")
            return original(value, context)

        with tempfile.TemporaryDirectory() as directory, \
                mock.patch.object(probe, "_normalize_candidate_evidence", side_effect=normalize):
            journal = probe.RawJournal(Path(directory) / "run.jsonl")
            with self.assertRaises(probe.ProbeError):
                probe.execute_candidate_mode(
                    candidate=candidate, candidate_version="v", mode="launch",
                    driver=Driver(), bridge=Bridge(), journal=journal,
                    launch_identity=identity,
                )

        self.assertEqual(order[:4], [
            "admission-enter", "launch", "bind", "admission-exit",
        ])

    def test_launch_exception_reconciles_before_ordered_cleanup(self):
        order = []
        candidate = "xcode-lldb-dap"
        class Driver:
            def launch(self, *arguments):
                order.append("spawned")
                raise RuntimeError("protocol failed after spawn")
            def close(self): order.append("candidate-close")
        class Bridge:
            @contextmanager
            def admission_boundary(self):
                try:
                    yield
                finally:
                    order.append("reconciled")
            def close(self): order.append("bridge-close")
            def supervisor_snapshot(self):
                order.append("snapshot")
                return {"cleanupComplete": True, "contexts": []}
        identity = probe.AcceptedLaunchIdentity(
            Path("/tmp/fixture"), "sha256:" + "a" * 64,
            "12345678-1234-1234-1234-123456789ABC", "signer", "N", 1,
            Path("/tmp"), (),
        )
        with tempfile.TemporaryDirectory() as directory:
            journal = probe.RawJournal(Path(directory) / "run.jsonl")
            with self.assertRaisesRegex(RuntimeError, "protocol failed"):
                probe.execute_candidate_mode(
                    candidate=candidate, candidate_version="v", mode="launch",
                    driver=Driver(), bridge=Bridge(), journal=journal,
                    launch_identity=identity,
                )
        self.assertEqual(order, [
            "spawned", "reconciled", "candidate-close", "bridge-close", "snapshot",
        ])

    def test_persistent_cli_attach_admission_is_composed_before_detach(self):
        order = []
        candidate = "macscope-lldb-cli-baseline"
        target = probe.drivers.ExactAttachTarget(
            42, 1, 501, 501, "/tmp/helper", 0x0100000C, 0,
            "exec", 1, 2, "12345678-1234-1234-1234-123456789ABC",
            "signer", "N",
        )
        attached = SimpleNamespace(
            candidate=candidate, semanticOperation="attach", observation="observed",
            requestID="run:attach", targetPID=42, targetDisposition="stopped",
            protocolFact={"source": "lldb-cli-transcript", "commandSequence": 1,
                          "sessionToken": "session"},
            negativeEvidence={},
        )
        detached = probe.drivers.CandidateOperationEvidence(
            candidate, "detach", "observed", "run:detach", 42, "detached", {},
        )
        class Driver:
            def attach_and_detach(self, *, pid, attach_request_id, detach_request_id,
                                  on_attached, post_detach_probe):
                order.append("attach")
                on_attached(attached)
                order.append("detach")
                return attached, detached
        class Context:
            @contextmanager
            def admission_boundary(self):
                order.append("boundary-enter")
                try:
                    yield
                finally:
                    order.append("boundary-exit")
            def observe_process(self, pid, operation):
                order.append("admitted")
                return SimpleNamespace()
            def post_detach_probe(self, pid): return {"pid": pid}
            def revalidate(self, value): return value == target
        class Control: pass

        result = probe._attach_candidate(
            candidate, Driver(), "run", target, Control(), Context(),
        )

        self.assertEqual(result[0].observation, "observed")
        self.assertEqual(order, [
            "boundary-enter", "attach", "admitted", "detach", "boundary-exit",
        ])

    def test_run_journals_historical_revisions_before_freezing_projection(self):
        candidate = "xcode-lldb-dap"
        target = probe.drivers.ExactAttachTarget(
            42, 1, 501, 501, "/tmp/helper", 0x0100000C, 0,
            "sha256:" + "a" * 64, 1, 2,
            "12345678-1234-1234-1234-123456789ABC", "signer", "N",
        )

        def observation(operation, lifecycle, stop):
            request_id = "run:" + operation
            evidence = {
                "request": {"id": request_id, "runID": "run", "sessionID": "session",
                    "sessionEpoch": 1, "lifecycleRevision": lifecycle,
                    "stopRevision": stop},
                "event": {"sequence": lifecycle, "name": operation,
                    "sessionID": "session", "sessionEpoch": 1,
                    "lifecycleRevision": lifecycle, "stopRevision": stop},
                "postcondition": {"operation": operation, "satisfied": True,
                    "detail": operation, "identity": None},
            }
            return probe.drivers.CandidateOperationEvidence(
                candidate, operation, "observed", request_id, 42,
                "running" if operation == "attach" else "detached",
                {"validatorEvidence": evidence},
            )

        class Driver:
            def attach_and_detach(self, attach_id, detach_id, pid, control):
                return observation("attach", 1, 0), observation("detach", 2, 1)
            def close(self): pass

        identity = {
            "pid": 42, "startTimeNS": 1, "realUID": 501, "effectiveUID": 501,
            "canonicalPath": "/tmp/helper", "cpuType": 0x0100000C, "cpuSubtype": 0,
            "executableIdentity": "sha256:" + "a" * 64, "nonce": "N", "role": "helper",
            "device": 1, "inode": 2,
            "machOUUID": "12345678-1234-1234-1234-123456789ABC",
        }
        artifacts = {
            "candidate": candidate, "mode": "attach",
            "processRegistry": [{"role": "helper", "identity": identity}],
            "cleanupReceipts": [{"role": "helper", "complete": True}],
            "residueAudit": {"auditedIdentities": [identity], "remainingIdentities": [],
                "complete": True, "evidence": {}},
            "signingEvidence": [],
        }
        class Bridge:
            @contextmanager
            def admission_boundary(self):
                yield
            def revalidate(self, value): return True
            def close(self): pass
            def supervisor_snapshot(self):
                return {"cleanupComplete": True, "contexts": [artifacts]}
        class Control:
            def close(self): pass

        with tempfile.TemporaryDirectory() as directory:
            journal = probe.RawJournal(Path(directory) / "run.jsonl")
            projection = probe.execute_candidate_mode(
                candidate=candidate, candidate_version="v", mode="attach",
                driver=Driver(), bridge=Bridge(), journal=journal,
                attach_target=target, attach_control=Control(),
            )
            raw = json.loads(journal.path.read_text().splitlines()[0])

        raw_events = [item["proof"]["validatorEvidence"]["event"]
                      for item in raw["payload"]["observations"]
                      if item["observation"] == "observed"]
        raw_observations = tuple(
            probe._candidate_evidence(item) for item in raw["payload"]["observations"]
        )
        projected = [item.proof["validatorEvidence"]["event"]
                     for item in projection.observations if item.observation == "observed"]
        self.assertEqual(
            tuple(item.operation for item in raw_observations),
            probe.schema.OPERATION_ORDER,
        )
        self.assertEqual(
            projection.observations,
            probe._freeze_run_revision_context(raw_observations),
        )
        self.assertEqual([(item["lifecycleRevision"], item["stopRevision"])
                          for item in raw_events], [(1, 0), (2, 1)])
        self.assertEqual([(item["lifecycleRevision"], item["stopRevision"])
                          for item in projected], [(2, 1), (2, 1)])

    def test_frozen_matrix_emits_one_context_three_discoveries_and_six_projections(self):
        target = probe.drivers.ExactAttachTarget(
            42, 1, 501, 501, "/tmp/helper", 0x0100000C, 0,
            "sha256:" + "a" * 64, 1, 2,
            "12345678-1234-1234-1234-123456789ABC", "signer", "N",
        )
        discoveries = {candidate: {"candidateVersion": "v-" + candidate,
            "discovery": {"state": "observed", "evidence": "exact tool discovery",
                          "toolchainBinding": "T"}}
            for candidate in probe.schema.CANDIDATE_ORDER}
        calls = []
        def run(candidate, mode, version):
            calls.append((candidate, mode))
            observations = tuple(probe._not_attempted(candidate, operation, candidate + mode)
                                 for operation in probe.schema.OPERATION_ORDER)
            return probe.CandidateRunProjection(
                candidate, version, mode, observations, target,
                hashlib.sha256((candidate + mode).encode()).hexdigest(),
                {"processRegistry": [], "cleanupReceipts": [], "cleanupComplete": True,
                 "residueAudit": {"auditedIdentities": [], "remainingIdentities": [],
                                  "complete": True, "evidence": {}}}, False,
            )
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            journal = probe.RawJournal(root / "matrix.jsonl")
            probe.emit_frozen_matrix(
                journal=journal, toolchain={"binding": "T"},
                fixture={"binding": "F", "processIdentities": {}, "moduleIdentities": []},
                normalization_root=root, discoveries=discoveries, run=run,
            )
            records = [json.loads(line) for line in journal.path.read_text().splitlines()]
        expected_calls = [(candidate, mode) for candidate in probe.schema.CANDIDATE_ORDER
                          for mode in ("launch", "attach")]
        self.assertEqual(calls, expected_calls)
        self.assertEqual([row["kind"] for row in records],
                         ["aggregate-context"] + ["candidate-discovery"] * 3
                         + ["candidate-run-projection"] * 6)

    def test_run_frozen_matrix_owns_six_fresh_contexts_and_prepares_each_cell(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            executable = root / "fixture"
            executable.write_bytes(b"fixture")
            executable.chmod(0o700)
            contexts = []

            def identity(pid, role, nonce):
                return {"pid": pid, "startTimeNS": pid * 1000, "realUID": 501,
                    "effectiveUID": 501, "canonicalPath": str(executable),
                    "cpuType": 0x0100000C, "cpuSubtype": 0,
                    "executableIdentity": "sha256:" + hashlib.sha256(b"fixture").hexdigest(),
                    "device": 1, "inode": pid, "machOUUID":
                    "12345678-1234-1234-1234-123456789ABC", "nonce": nonce,
                    "role": role}

            class Control:
                def __init__(self, pid, nonce): self.pid, self.nonce, self.closed = pid, nonce, False
                def send(self, operation): return {"operation": operation, "pid": self.pid,
                                                    "sequence": 1, "nonce": self.nonce}
                def close(self): self.closed = True

            class Context:
                def __init__(self, candidate, mode, arguments):
                    self.candidate, self.mode, self.arguments = candidate, mode, arguments
                    self.index = len(contexts) + 1
                    self.closed = False
                    self.prepared = False
                    contexts.append(self)
                @contextmanager
                def admission_boundary(self):
                    yield
                def prepare_launch(self):
                    self.prepared = True
                    return probe.AcceptedLaunchIdentity(
                        executable, "sha256:" + hashlib.sha256(b"fixture").hexdigest(),
                        "12345678-1234-1234-1234-123456789ABC", "signer",
                        f"launch-{self.index}", 1, root, (),
                    )
                def prepare_attach_helper(self):
                    self.prepared = True
                    pid, nonce = 100 + self.index, f"attach-{self.index}"
                    return (probe.drivers.ExactAttachTarget(
                        pid, pid * 1000, 501, 501, str(executable), 0x0100000C, 0,
                        "sha256:" + hashlib.sha256(b"fixture").hexdigest(), 1, pid,
                        "12345678-1234-1234-1234-123456789ABC", "signer", nonce,
                    ), Control(pid, nonce))
                def revalidate(self, target): return True
                def close(self): self.closed = True
                def supervisor_snapshot(self):
                    self.assert_closed()
                    role = "target" if self.mode == "launch" else "helper"
                    pid = (200 + self.index) if self.mode == "launch" else (100 + self.index)
                    nonce = f"{self.mode}-{self.index}"
                    value = identity(pid, role, nonce)
                    return {"cleanupComplete": True, "candidate": self.candidate,
                        "mode": self.mode,
                        "processRegistry": [{"role": role, "identity": value}],
                        "cleanupReceipts": [{"role": role, "complete": True}],
                        "residueAudit": {"auditedIdentities": [value],
                            "remainingIdentities": [], "complete": True, "evidence": {}},
                        "signingEvidence": [{"role": role, "signingIdentity": "signer"}]}
                def assert_closed(self):
                    if not self.closed: raise AssertionError("snapshot preceded close")

            class Bridge:
                @staticmethod
                def make_run_context(candidate, mode, arguments):
                    return Context(candidate, mode, arguments)

            class Driver:
                def __init__(self, context): self.candidate, self.context = context.candidate, context
                def launch(self, request, executable, arguments, cwd, environment):
                    return probe.drivers.CandidateOperationEvidence(
                        self.candidate, "launch", "observed", request,
                        200 + self.context.index, "running", {"protocol": "fact"})
                def exercise_operation(self, request, operation, context):
                    return probe._not_attempted(self.candidate, operation, request,
                                                200 + self.context.index)
                def attach_and_detach(self, attach, detach, pid, control):
                    return (probe.drivers.CandidateOperationEvidence(
                        self.candidate, "attach", "observed", attach, pid, "running", {}),
                        probe.drivers.CandidateOperationEvidence(
                        self.candidate, "detach", "observed", detach, pid, "detached", {}))
                def attach(self, request, target):
                    return probe.drivers.CandidateOperationEvidence(
                        self.candidate, "attach", "observed", request,
                        target.pid, "running", {})
                def detach(self, request, control=None):
                    pid = 100 + self.context.index
                    proof = {"protocolResponse": {"result": {"postDetach": {
                        "sameIdentity": True, "alive": True, "controllable": True,
                        "checkpointSequence": 11, "pid": pid,
                        "nonce": f"attach-{self.context.index}",
                    }}}} if self.candidate == "xcode-lldb-python-json" else {}
                    return probe.drivers.CandidateOperationEvidence(
                        self.candidate, "detach", "observed", request,
                        pid, "detached", proof)
                def close(self): return None

            discoveries = {candidate: {"candidateVersion": "v",
                "discovery": {"state": "observed", "evidence": "exact",
                              "toolchainBinding": "T"}}
                for candidate in probe.schema.CANDIDATE_ORDER}
            journal = probe.RawJournal(root / "matrix.jsonl")
            with mock.patch.object(probe, "_make_candidate_driver",
                                   side_effect=lambda candidate, runner, context: Driver(context)):
                probe.run_frozen_matrix(
                    bridge_module=Bridge(), runner=object(), journal=journal,
                    toolchain={"binding": "T"}, fixture={"binding": "F"},
                    normalization_root=root, discoveries=discoveries,
                    per_cell_arguments={
                        "control_root": str(root), "started_after_ns": 1,
                        "nonce_seed": "matrix", "executable": str(executable),
                        "helper": str(executable),
                        "executable_identity": "sha256:" + hashlib.sha256(b"fixture").hexdigest(),
                        "helper_executable_identity": "sha256:" + hashlib.sha256(b"fixture").hexdigest(),
                        "macho_uuid": "12345678-1234-1234-1234-123456789ABC",
                        "helper_macho_uuid": "12345678-1234-1234-1234-123456789ABC",
                        "signing_identity": "signer", "argument": (),
                        "helper_signing_identity": "signer",
                    },
                )
            rows = [json.loads(line) for line in journal.path.read_text().splitlines()]
        self.assertEqual(len(contexts), 6)
        self.assertEqual(len({id(value) for value in contexts}), 6)
        self.assertTrue(all(value.prepared and value.closed for value in contexts))
        self.assertEqual(sum(row["kind"] == "candidate-run-projection" for row in rows), 6)

    def test_discovery_and_launch_record_real_driver_evidence_without_verdicts(self):
        with tempfile.TemporaryDirectory() as directory:
            journal = probe.RawJournal(Path(directory) / "raw.jsonl")
            coordinator = probe.ProbeCoordinator(FakeDriver("xcode-lldb-dap"), PythonDriver(),
                FakeDriver("macscope-lldb-cli-baseline"), journal)
            discovery = coordinator.discovery()
            runs = coordinator.launch(Path("/tmp/fixture"), ("a",), Path("/tmp"), {})
            self.assertEqual([row["candidate"] for row in discovery], list(probe.schema.CANDIDATE_ORDER))
            self.assertEqual(runs["xcode-lldb-dap"][0].observation, "observed")
            self.assertNotIn("pass", json.loads(journal.path.read_text().splitlines()[-1]))

    def test_attach_wires_exact_pre_post_revalidation_and_detach_control(self):
        with tempfile.TemporaryDirectory() as directory:
            coordinator = probe.ProbeCoordinator(FakeDriver("xcode-lldb-dap"), PythonDriver(),
                FakeDriver("macscope-lldb-cli-baseline"),
                probe.RawJournal(Path(directory) / "raw.jsonl"))
            target = probe.drivers.ExactAttachTarget(42, 1, 501, 501, "/tmp/helper", 0x0100000C, 0,
                "exec", 1, 2, "12345678-1234-1234-1234-123456789ABC", "signer", "N")
            class Control:
                pid, nonce = 42, "N"
                def send(self, operation): return {"operation": operation, "pid": 42}
            checks = []
            result = coordinator.attach(target, Control(), lambda value: checks.append(value) or True)
            self.assertEqual(len(checks), 4)
            self.assertEqual(result["xcode-lldb-dap"][-1].targetDisposition, "detached")

    def test_python_attach_reuses_detach_checkpoint_without_outer_control_send(self):
        target = probe.drivers.ExactAttachTarget(
            42, 1, 501, 501, "/tmp/helper", 0x0100000C, 0,
            "exec", 1, 2, "12345678-1234-1234-1234-123456789ABC", "signer", "N",
        )
        class Driver:
            def attach(self, request, value):
                return probe.drivers.CandidateOperationEvidence(
                    "xcode-lldb-python-json", "attach", "observed", request,
                    value.pid, "stopped", {},
                )
            def detach(self, request):
                return probe.drivers.CandidateOperationEvidence(
                    "xcode-lldb-python-json", "detach", "observed", request,
                    target.pid, "detached", {
                        "protocolResponse": {"result": {"postDetach": {
                            "sameIdentity": True, "alive": True, "controllable": True,
                            "checkpointSequence": 17, "pid": target.pid,
                            "canonicalPath": target.canonicalPath, "nonce": target.nonce,
                        }}}
                    },
                )
        class Control:
            def send(self, operation):
                raise AssertionError("outer control must not duplicate the detach checkpoint")
        class Context:
            @contextmanager
            def admission_boundary(self):
                yield
            def revalidate(self, value): return value == target

        observations = probe._attach_candidate(
            "xcode-lldb-python-json", Driver(), "run", target, Control(), Context(),
        )

        checkpoint = observations[-1].proof["postDetachControl"]
        self.assertEqual(checkpoint, {
            "operation": "checkpoint", "commandSequence": 17,
            "pid": target.pid, "nonce": target.nonce,
        })

    def test_python_attach_exposes_reused_checkpoint_to_detach_metadata_projection(self):
        target = probe.drivers.ExactAttachTarget(
            43, 2, 501, 501, "/tmp/helper", 0x0100000C, 0,
            "exec", 1, 3, "12345678-1234-1234-1234-123456789ABC", "signer", "nonce-43",
        )
        class Driver:
            def attach(self, request, value):
                return probe.drivers.CandidateOperationEvidence(
                    "xcode-lldb-python-json", "attach", "observed", request,
                    value.pid, "stopped", {},
                )
            def detach(self, request):
                return probe.drivers.CandidateOperationEvidence(
                    "xcode-lldb-python-json", "detach", "observed", request,
                    target.pid, "detached", {
                        "protocolResponse": {"evidence": {"postcondition": {
                            "survivalProof": {
                                "sameIdentity": True, "alive": True,
                                "controllable": True, "checkpointSequence": 23,
                                "pid": target.pid, "nonce": target.nonce,
                            }
                        }}}
                    },
                )
        class Control:
            def send(self, operation):
                raise AssertionError("outer control must not send")
        class Context:
            @contextmanager
            def admission_boundary(self):
                yield
            def revalidate(self, value): return value == target

        observations = probe._attach_candidate(
            "xcode-lldb-python-json", Driver(), "run", target, Control(), Context(),
        )

        self.assertEqual(
            probe._post_detach_checkpoint(observations[-1].proof)["commandSequence"],
            23,
        )

    def test_launch_exercises_the_complete_frozen_launch_matrix(self):
        class MatrixDriver(FakeDriver):
            def __init__(self, candidate):
                super().__init__(candidate)
                self.exercised = []
            def exercise_operation(self, request, operation, context):
                self.exercised.append(operation)
                return probe.drivers.CandidateOperationEvidence(
                    self.candidate, operation, "notAttempted", request, 42,
                    "targetDispositionUnknown", {},
                    {"classification": "notAttempted", "stage": operation})
        with tempfile.TemporaryDirectory() as directory:
            dap_driver = MatrixDriver("xcode-lldb-dap")
            cli_driver = MatrixDriver("macscope-lldb-cli-baseline")
            coordinator = probe.ProbeCoordinator(
                dap_driver, PythonDriver(), cli_driver,
                probe.RawJournal(Path(directory) / "raw.jsonl"),
            )
            result = coordinator.launch(Path("/tmp/fixture"), (), Path("/tmp"), {})
        expected = [
            name for name in probe.schema.OPERATION_ORDER
            if name not in {"configuredLaunch", "attach", "detach"}
        ]
        self.assertEqual(dap_driver.exercised, expected)
        self.assertEqual(
            [item.operation for item in result["xcode-lldb-dap"]],
            ["launch", *expected],
        )

    def test_coordinator_closes_candidate_resources_before_supervisor_snapshot(self):
        order = []
        class ClosingDriver(FakeDriver):
            def close(self):
                order.append(self.candidate)
                return None
        with tempfile.TemporaryDirectory() as directory:
            coordinator = probe.ProbeCoordinator(
                ClosingDriver("xcode-lldb-dap"), PythonDriver(),
                ClosingDriver("macscope-lldb-cli-baseline"),
                probe.RawJournal(Path(directory) / "raw.jsonl"),
            )
            snapshot = coordinator.close_then_snapshot(
                lambda: order.append("snapshot") or {"complete": True}
            )
        self.assertEqual(order[-1], "snapshot")
        self.assertEqual(snapshot, {"complete": True})


class ReportTests(unittest.TestCase):
    def test_dap_projection_renders_structured_postcondition_as_nonempty_detail(self):
        module = {
            "path": "/private/tmp/ws18/Fixture.framework/Fixture",
            "machOUUID": "55555555-5555-5555-5555-555555555555",
        }
        context = SimpleNamespace(candidate="xcode-lldb-dap", mode="launch")
        protocol = SimpleNamespace(
            requestID="run-7:threadList",
            wireCommands=({"requestSequence": 9},),
            semanticOperation="threadList",
            sessionEpoch=7,
            lifecycleRevision=11,
            stopRevision=4,
            postcondition={"responseField": "threads", "itemCount": 2},
        )
        runtime = SimpleNamespace(evidence=module)

        projected = probe._project_dap_validator_evidence(context, protocol, runtime)

        detail = projected["validatorEvidence"]["postcondition"]["detail"]
        self.assertIsInstance(detail, str)
        self.assertTrue(detail.strip())

    def test_dap_projection_accepts_bound_configured_launch_causal_sequence(self):
        context = SimpleNamespace(candidate="xcode-lldb-dap", mode="launch")
        protocol = SimpleNamespace(
            requestID="run-7:configuredLaunch",
            wireCommands=(
                {"command": "launch", "requestSequence": 9},
                {"command": "continue", "requestSequence": 10},
                {"command": "threads", "requestSequence": 11},
                {"command": "pause", "requestSequence": 12},
            ),
            semanticOperation="configuredLaunch",
            sessionEpoch=7, lifecycleRevision=13, stopRevision=5,
            postcondition={"runtimeBoundWhileRunning": True,
                           "restoredStoppedPID": 42},
        )
        runtime = SimpleNamespace(evidence={"pid": 42, "nonce": "N"})

        projected = probe._project_dap_validator_evidence(
            context, protocol, runtime)

        event = projected["validatorEvidence"]["event"]
        self.assertEqual(event["sequence"], 9)
        self.assertEqual(event["name"], "configuredLaunch")

    def test_module_projection_uses_only_exact_protocol_module_identity(self):
        module = {
            "path": "/private/tmp/ws18/Fixture.framework/Fixture",
            "machOUUID": "55555555-5555-5555-5555-555555555555",
        }
        process = self._identity("target", 700)
        context = SimpleNamespace(candidate="xcode-lldb-dap", mode="launch")
        base = dict(
            requestID="run-7:moduleList",
            wireCommands=({"requestSequence": 9},), semanticOperation="moduleList",
            sessionEpoch=7, lifecycleRevision=11, stopRevision=4,
        )
        observed = SimpleNamespace(**base, postcondition={"moduleIdentity": module})
        missing = SimpleNamespace(**base, postcondition={"itemCount": 1})

        proved = probe._project_dap_validator_evidence(
            context, observed, SimpleNamespace(evidence=process),
        )
        unproved = probe._project_dap_validator_evidence(
            context, missing, SimpleNamespace(evidence=process),
        )

        self.assertEqual(proved["validatorEvidence"]["postcondition"]["identity"], module)
        self.assertIsNone(unproved["validatorEvidence"]["postcondition"]["identity"])

    def test_supervisor_merge_hashes_ordered_identities_not_registry_wrappers(self):
        validator = probe._load("validate_ws18")
        adapter = self._identity("adapter", 600)
        target = self._identity("target", 700)
        snapshot = {
            "candidate": "xcode-lldb-dap", "mode": "launch",
            "processRegistry": [
                {"role": "adapter", "identity": adapter},
                {"role": "target", "identity": target},
            ],
            "cleanupReceipts": [],
            "residueAudit": {
                "auditedIdentities": [adapter, target],
                "remainingIdentities": [], "complete": True, "evidence": {},
            },
            "signingEvidence": [], "metadata": {},
        }

        merged = probe._merge_supervisor_contexts(snapshot, "xcode-lldb-dap", "launch")

        self.assertEqual(
            merged["residueAudit"]["evidence"]["registryDigest"],
            validator._registry_digest([adapter, target]),
        )

    def test_attach_run_derives_frozen_detach_metadata_from_protocol_facts(self):
        target = probe.drivers.ExactAttachTarget(
            701, 9_702, 501, 501, "/private/tmp/ws18/helper", 0x0100000C, 0,
            "uuid:helper;device:1;inode:701", 1, 701,
            "11111111-2222-3333-4444-555555555555", "signer", "nonce-helper",
        )
        attached = self._observation("xcode-lldb-dap", "attach", 1, "attach")
        detached = self._observation("xcode-lldb-dap", "detach", 2, "attach")
        detached_proof = dict(detached.proof)
        detached_proof["protocolFact"] = {
            "postcondition": {"postDetachControl": {
                "operation": "checkpoint", "pid": 701,
                "commandSequence": 50, "nonce": "nonce-helper",
            }}
        }
        detached = probe.drivers.CandidateOperationEvidence(
            detached.candidate, detached.operation, detached.observation,
            detached.requestID, detached.targetPID, detached.targetDisposition,
            detached_proof, detached.negative,
        )
        artifacts = self._artifacts("attach")
        artifacts["metadata"] = {
            "adapterStartedInNewSession": True,
            "helperStartedInNewSession": True,
            "adapterHelperSessionsDistinct": True,
            "pidEvidenceSource": "adapter",
        }

        run = probe.make_run(
            "xcode-lldb-dap", "v", "attach", (attached, detached), target,
            "T", "F", "journal", supervisor_artifacts=artifacts,
        )

        metadata = run["metadata"]
        self.assertEqual(metadata["explicitAdapterPID"], 701)
        self.assertTrue(metadata["explicitDetachAcknowledged"])
        self.assertEqual(metadata["detachAcknowledgementSessionID"], "session-7")
        self.assertFalse(metadata["disconnectTerminateDebuggee"])
        self.assertTrue(metadata["helperAliveAfterDetach"])
        self.assertTrue(metadata["helperControllableAfterDetach"])
        self.assertEqual(metadata["postDetachIdentity"], self._identity("helper", 701))
        self.assertEqual(metadata["postDetachControlEvidence"]["sequence"], 50)

    def test_freezing_run_revisions_preserves_step_request_stop_history(self):
        before_step = self._observation("xcode-lldb-dap", "threadList", 1, "launch")
        stepped = self._observation("xcode-lldb-dap", "stepInto", 2, "launch")
        stepped_proof = copy.deepcopy(stepped.proof)
        stepped_proof["validatorEvidence"]["request"]["stopRevision"] = 3
        stepped_proof["validatorEvidence"]["event"]["stopRevision"] = 4
        stepped = probe.drivers.CandidateOperationEvidence(
            stepped.candidate, stepped.operation, stepped.observation,
            stepped.requestID, stepped.targetPID, stepped.targetDisposition,
            stepped_proof, stepped.negative,
        )

        frozen = probe._freeze_run_revision_context((before_step, stepped))
        step_evidence = frozen[1].proof["validatorEvidence"]

        self.assertEqual(step_evidence["request"]["stopRevision"], 3)
        self.assertEqual(step_evidence["event"]["stopRevision"], 4)
        self.assertEqual(probe._observed_context(frozen)["stopRevision"], 4)

    def test_protocol_fact_digest_index_is_exactly_candidate_and_mode_bound(self):
        observations = tuple(probe._not_attempted(
            "xcode-lldb-dap", operation, "run"
        ) for operation in probe.schema.OPERATION_ORDER)
        records = [{
            "kind": "candidate-protocol-facts",
            "payload": {"candidate": "xcode-lldb-dap", "mode": "launch",
                        "observations": [probe._jsonable(probe.asdict(item))
                                         for item in observations]},
            "recordSHA256": "a" * 64,
        }]

        index = probe._protocol_fact_digest_index(records)

        self.assertEqual(index[("xcode-lldb-dap", "launch")],
                         ("a" * 64, observations))
        self.assertNotIn(("xcode-lldb-dap", "attach"), index)

    def test_launch_probe_plan_runs_only_causally_complete_terminal_baseline(self):
        operations = probe._launch_probe_operations()

        self.assertEqual(operations, ("terminate", "expectedExit"))

    def test_failed_launch_outcome_is_not_replaced_by_trailing_not_attempted_rows(self):
        target = probe.drivers.ExactAttachTarget(42, 1, 501, 501, "/tmp/helper",
            0x0100000C, 0, "exec", 1, 2,
            "12345678-1234-1234-1234-123456789ABC", "signer", "N")
        failed = probe.drivers.CandidateOperationEvidence(
            "xcode-lldb-dap", "launch", "protocolError", "launch-request", None,
            "targetDispositionUnknown", {},
            {"classification": "protocolError", "diagnosticPreview": "failed"},
        )
        trailing = probe.drivers.CandidateOperationEvidence(
            "xcode-lldb-dap", "adapterCrashRecovery", "notAttempted", "later-request", None,
            "targetDispositionUnknown", {},
            {"classification": "notAttempted", "diagnosticPreview": "not exercised"},
        )
        run = probe.make_run("xcode-lldb-dap", "v", "launch", (failed, trailing),
            target, "T", "F", "journal", supervisor_artifacts=self._no_process_artifacts())
        self.assertEqual(run["outcome"]["state"], "protocolError")

    def test_operation_rows_have_frozen_order_and_no_candidate_verdict(self):
        item = probe.drivers.CandidateOperationEvidence("xcode-lldb-dap", "attach", "observed",
            "R", 42, "running", {"processId": 42})
        rows, ledger = probe._operation_rows((item,))
        self.assertEqual([row["name"] for row in rows], list(probe.schema.OPERATION_ORDER))
        self.assertEqual(len(ledger), 1)
        self.assertEqual(next(row for row in rows if row["name"] == "attach")["observation"], "harnessError")
        self.assertFalse(any("pass" in row or "eligible" in row for row in rows))

    def test_validator_handoff_invokes_independent_validator(self):
        calls = []
        class Result: returncode = 1
        def runner(command, check):
            calls.append((command, check)); return Result()
        code = probe.validator_handoff(Path("/tmp/report.json"), ("--require-launch",), runner)
        self.assertEqual(code, 1)
        self.assertTrue(calls[0][0][1].endswith("validate_ws18.py"))
        self.assertFalse(calls[0][1])

    def test_negative_aggregate_is_structurally_valid_without_authoring_pass(self):
        validator = probe._load("validate_ws18")
        target = probe.drivers.ExactAttachTarget(42, 1, 501, 501, "/tmp/helper", 0x0100000C, 0,
            "exec", 1, 2, "12345678-1234-1234-1234-123456789ABC", "signer", "N")
        candidates = []
        for candidate in probe.schema.CANDIDATE_ORDER:
            state = "unsupported" if candidate == "xcode-lldb-python-json" else "harnessError"
            runs = []
            for mode in ("launch", "attach"):
                evidence = probe.drivers.CandidateOperationEvidence(candidate, mode, state,
                    mode + "-request", 42, "targetDispositionUnknown", {},
                    {"classification": state, "diagnosticPreview": "attempted"})
                runs.append(probe.make_run(candidate, "v", mode, (evidence,), target,
                                           "T", "F", "journal",
                                           supervisor_artifacts=self._no_process_artifacts()))
            candidates.append(probe.schema.make_candidate(candidate, "v",
                {"state": "structurallyUnsupported" if candidate == "xcode-lldb-python-json" else "observed",
                 "evidence": "discovery", "toolchainBinding": "T"}, runs))
        fixture_processes = {
            role: {key: value for key, value in probe._identity(target, role).items()
                   if key not in {"pid", "startTimeNS", "realUID", "effectiveUID", "nonce"}}
            for role in ("target", "helper")
        }
        aggregate = probe.schema.make_aggregate(toolchain={"binding": "T"},
            fixture={"binding": "F", "processIdentities": fixture_processes,
                     "moduleIdentities": [{"path": "/private/tmp/ws18/Fixture.framework/Fixture",
                                           "machOUUID": "55555555-5555-5555-5555-555555555555"}]},
            normalization=probe.schema.make_normalization(),
            candidates=candidates, validator=probe.schema.make_validator_envelope())
        aggregate = probe.schema.seal_validator_digest(aggregate)
        result = validator.validate_report(aggregate)
        self.assertTrue(result.structurally_valid, result.issues)
        self.assertNotIn("pass", json.dumps(aggregate))

    @staticmethod
    def _identity(role, pid):
        return {
            "pid": pid, "startTimeNS": 9_001 + pid, "realUID": 501,
            "effectiveUID": 501, "canonicalPath": f"/private/tmp/ws18/{role}",
            "cpuType": 0x0100000C, "cpuSubtype": 0,
            "executableIdentity": f"uuid:{role};device:1;inode:{pid}",
            "nonce": f"nonce-{role}", "role": role, "device": 1,
            "inode": pid, "machOUUID": "11111111-2222-3333-4444-555555555555",
        }

    @classmethod
    def _artifacts(cls, mode):
        role = "target" if mode == "launch" else "helper"
        adapter = cls._identity("adapter", 600 if mode == "launch" else 601)
        debuggee = cls._identity(role, 700 if mode == "launch" else 701)
        identities = [adapter, debuggee]
        registry_digest = hashlib.sha256(json.dumps(
            identities, sort_keys=True, separators=(",", ":")
        ).encode()).hexdigest()
        receipts = []
        for identity in identities:
            receipts.append({
                "role": identity["role"], "expectedIdentity": identity,
                "observedIdentity": identity, "revalidated": True,
                "action": "gracefulExit" if identity["role"] == "adapter" else "fixtureExit",
                "terminalState": "gone", "complete": True,
                "detail": "exact identity is gone", "ownershipEvidence": None,
            })
        return {
            "processRegistry": [
                {"role": identity["role"], "identity": identity} for identity in identities
            ],
            "cleanupReceipts": receipts,
            "residueAudit": {
                "auditedIdentities": identities, "remainingIdentities": [],
                "complete": True,
                "evidence": {"reinspection": "exactIdentity",
                             "registryDigest": registry_digest, "remainingCount": 0},
            },
            "metadata": {
                "adapterStartedInNewSession": True,
                "helperStartedInNewSession": True,
                "adapterHelperSessionsDistinct": True,
                "pidEvidenceSource": "adapter", "hybrid": False,
                "explicitAdapterPID": debuggee["pid"],
                "explicitDetachAcknowledged": mode == "attach",
                "detachAcknowledgementSessionID": "session-7" if mode == "attach" else "",
                "disconnectTerminateDebuggee": False if mode == "attach" else True,
                "helperAliveAfterDetach": mode == "attach",
                "helperControllableAfterDetach": mode == "attach",
                "postDetachIdentity": debuggee if mode == "attach" else None,
                "postDetachControlEvidence": {
                    "requestID": "run-7", "sessionID": "session-7",
                    "sessionEpoch": 7, "lifecycleRevision": 11,
                    "nonce": debuggee["nonce"], "sequence": 50,
                    "postcondition": "same helper answered after detach",
                } if mode == "attach" else None,
            },
        }

    @staticmethod
    def _no_process_artifacts():
        return {
            "processRegistry": [], "cleanupReceipts": [],
            "residueAudit": {
                "auditedIdentities": [], "remainingIdentities": [], "complete": True,
                "evidence": {
                    "reinspection": "exactIdentity",
                    "registryDigest": hashlib.sha256(b"[]").hexdigest(),
                    "remainingCount": 0,
                },
            },
            "metadata": {},
        }

    @classmethod
    def _observation(cls, candidate, operation, sequence, mode):
        request_id = f"{candidate}-{mode}-{operation}"
        module_identity = {
            "path": "/private/tmp/ws18/Fixture.framework/Fixture",
            "machOUUID": "55555555-5555-5555-5555-555555555555",
        }
        evidence = {
            "request": {"id": request_id, "runID": "run-7",
                        "sessionID": "session-7", "sessionEpoch": 7,
                        "lifecycleRevision": 11,
                        "stopRevision": 3 if operation in probe.drivers.dap.__dict__.get("STEP_OPERATIONS", ()) else 4},
            "event": {"sequence": sequence, "sessionID": "session-7",
                      "sessionEpoch": 7, "lifecycleRevision": 11,
                      "stopRevision": 4, "name": operation},
            "postcondition": {"operation": operation, "satisfied": True,
                              "detail": f"proved {operation}",
                              "identity": module_identity if operation in {
                                  "moduleList", "moduleLoad", "moduleUnload"} else None},
        }
        return probe.drivers.CandidateOperationEvidence(
            candidate, operation, "observed", request_id,
            700 if mode == "launch" else 701,
            "exited" if mode == "launch" else "detached",
            {"validatorEvidence": evidence},
        )

    def test_make_run_derives_context_ledger_identity_and_cleanup_without_synthesis(self):
        target = probe.drivers.ExactAttachTarget(
            701, 9_702, 501, 501, "/private/tmp/ws18/helper", 0x0100000C, 0,
            "uuid:helper;device:1;inode:701", 1, 701,
            "11111111-2222-3333-4444-555555555555", "signer", "nonce-helper",
        )
        observations = (
            self._observation("xcode-lldb-dap", "attach", 1, "attach"),
            self._observation("xcode-lldb-dap", "detach", 2, "attach"),
        )
        run = probe.make_run(
            "xcode-lldb-dap", "v", "attach", observations, target,
            "T", "F", "journal", supervisor_artifacts=self._artifacts("attach"),
        )
        self.assertEqual(run["requestID"], "run-7")
        self.assertEqual(run["sessionID"], "session-7")
        self.assertEqual((run["sessionEpoch"], run["lifecycleRevision"], run["stopRevision"]),
                         (7, 11, 4))
        self.assertEqual(run["observedIdentity"], self._identity("helper", 701))
        ledger = run["rawBindings"]["requestLedger"]
        self.assertEqual([row["requestID"] for row in ledger],
                         [item.requestID for item in observations])
        self.assertEqual([row["responseEventSequence"] for row in ledger], [1, 2])
        self.assertEqual(run["cleanupReceipts"], self._artifacts("attach")["cleanupReceipts"])

    def test_make_run_without_supervisor_proof_never_claims_clean_residue(self):
        target = probe.drivers.ExactAttachTarget(
            701, 9_702, 501, 501, "/private/tmp/ws18/helper", 0x0100000C, 0,
            "uuid:helper;device:1;inode:701", 1, 701,
            "11111111-2222-3333-4444-555555555555", "signer", "nonce-helper",
        )
        observed = self._observation("xcode-lldb-dap", "attach", 1, "attach")
        run = probe.make_run("xcode-lldb-dap", "v", "attach", (observed,), target,
                             "T", "F", "journal")
        self.assertEqual(run["outcome"]["state"], "harnessError")
        self.assertFalse(run["residueAudit"]["complete"])
        self.assertNotEqual(run["residueAudit"]["evidence"].get("reinspection"),
                            "noProcessSpawned")

    def test_report_projection_builds_frozen_three_by_two_sealed_aggregate(self):
        validator = probe._load("validate_ws18")
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            root.chmod(0o700)
            journal = probe.RawJournal(root / "projection.jsonl", artifact_root=root)
            target = probe.drivers.ExactAttachTarget(
                42, 1, 501, 501, "/private/tmp/ws18/helper", 0x0100000C, 0,
                "uuid:helper;device:1;inode:2", 1, 2,
                "12345678-1234-1234-1234-123456789ABC", "signer", "N",
            )
            fixture_processes = {
                role: {key: value for key, value in probe._identity(target, role).items()
                       if key not in {"pid", "startTimeNS", "realUID", "effectiveUID", "nonce"}}
                for role in ("target", "helper")
            }
            journal.append("aggregate-context", {
                "toolchain": {"binding": "T"},
                "fixture": {"binding": "F", "processIdentities": fixture_processes,
                    "moduleIdentities": [{"path": "/private/tmp/ws18/Fixture.framework/Fixture",
                        "machOUUID": "55555555-5555-5555-5555-555555555555"}]},
                "normalizationRoot": str(root),
            })
            target_payload = {
                "pid": target.pid, "startTimeNS": target.startTimeNS,
                "realUID": target.realUID, "effectiveUID": target.effectiveUID,
                "canonicalPath": target.canonicalPath, "cpuType": target.cpuType,
                "cpuSubtype": target.cpuSubtype,
                "executableIdentity": target.executableIdentity,
                "executableDevice": target.executableDevice,
                "executableInode": target.executableInode,
                "machOUUID": target.machOUUID, "signingIdentity": target.signingIdentity,
                "nonce": target.nonce,
            }
            for candidate in probe.schema.CANDIDATE_ORDER:
                unsupported = candidate == "xcode-lldb-python-json"
                journal.append("candidate-discovery", {
                    "candidate": candidate, "candidateVersion": "v",
                    "discovery": {"state": "structurallyUnsupported" if unsupported else "observed",
                        "evidence": "selected Xcode discovery", "toolchainBinding": "T"},
                })
                for mode in ("launch", "attach"):
                    state = "unsupported" if unsupported else "harnessError"
                    observations = [probe.drivers.CandidateOperationEvidence(
                        candidate, operation, state,
                        f"{candidate}-{mode}-{operation}", None,
                        "targetDispositionUnknown", {},
                        {"classification": state, "diagnosticPreview": "attempted"},
                    ) for operation in probe.schema.OPERATION_ORDER]
                    protocol_digest = journal.append("candidate-protocol-facts", {
                        "candidate": candidate, "mode": mode,
                        "observations": [probe._jsonable(probe.asdict(item))
                                         for item in observations],
                    })
                    journal.append("candidate-run-projection", {
                        "candidate": candidate, "candidateVersion": "v", "mode": mode,
                        "observations": [probe._jsonable(probe.asdict(item)) for item in observations],
                        "target": target_payload, "journalDigest": protocol_digest,
                        "supervisorArtifacts": self._no_process_artifacts(),
                    })
            journal.close()
            output = root / "report.json"
            digest = probe.aggregate_report_from_journals((journal.path,), output,
                                                          artifact_root=root)
            report = probe.schema.load_aggregate(output)
            result = validator.validate_report(report)
            self.assertTrue(result.structurally_valid, result.issues)
            self.assertTrue(probe.schema.validator_digest_matches(report))
            self.assertEqual(len(digest), 64)
            self.assertEqual(
                [(item["candidate"], tuple(run["mode"] for run in item["runs"]))
                 for item in report["candidates"]],
                [(candidate, ("launch", "attach")) for candidate in probe.schema.CANDIDATE_ORDER],
            )
            tampered = copy.deepcopy(probe._raw_records((journal.path,), root))
            projection = next(item for item in tampered
                              if item["kind"] == "candidate-run-projection")
            projection["payload"]["journalDigest"] = "0" * 64
            with mock.patch.object(probe, "_raw_records", return_value=tampered):
                with self.assertRaisesRegex(probe.ProbeError, "not bound"):
                    probe.aggregate_report_from_journals(
                        (journal.path,), root / "tampered-report.json", artifact_root=root,
                    )

            forged_projection = copy.deepcopy(probe._raw_records((journal.path,), root))
            projection = next(item for item in forged_projection
                              if item["kind"] == "candidate-run-projection")
            projection["payload"]["observations"][0]["requestID"] = "forged-request"
            with mock.patch.object(probe, "_raw_records", return_value=forged_projection):
                with self.assertRaisesRegex(probe.ProbeError, "not derived"):
                    probe.aggregate_report_from_journals(
                        (journal.path,), root / "forged-report.json", artifact_root=root,
                    )

    def test_report_projection_rejects_attempted_process_without_supervisor_cleanup(self):
        observation = probe.drivers.CandidateOperationEvidence(
            "xcode-lldb-dap", "configuredLaunch", "protocolError", "request", 42,
            "targetDispositionUnknown", {},
            {"classification": "protocolError", "diagnosticPreview": "attempted"},
        )
        with self.assertRaisesRegex(probe.ProbeError, "cleanup"):
            probe._require_attempt_cleanup((observation,), self._no_process_artifacts())


if __name__ == "__main__":
    unittest.main()
