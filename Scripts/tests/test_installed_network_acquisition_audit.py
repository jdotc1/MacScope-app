from __future__ import annotations

import hashlib
import os
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest import mock
from pathlib import Path
from Scripts.reconstruction import audit_installed_network_acquisition as network_audit
from Scripts.reconstruction.network_process_watch import ProcessWatchCollector
from Scripts.tests.test_network_process_watch import Queue, event, registration_event


class MatrixClassificationTests(unittest.TestCase):
    def classify(self, payload, candidates=frozenset({42}), foreign=frozenset({1})):
        return network_audit.classify_matrix_observation(payload, candidate_pids=candidates, foreign_pids=foreign)

    def test_every_row_retained_and_classified_without_name_authority(self):
        payload = b",bytes_in,bytes_out,\nMacScope.1,9,8,\nforeign-name.42,0,0,\nlaunchd.99,0,0,\n"
        self.assertEqual(self.classify(payload), network_audit.MatrixObservationSummary(1, 3, 1, 1, 1))

    def test_header_only_and_consistent_crlf_are_valid(self):
        self.assertEqual(self.classify(b",bytes_in,bytes_out,\r\n").process_row_count, 0)
        self.assertEqual(self.classify(b",bytes_in,bytes_out,\n" * 2).sample_count, 2)

    def test_unknown_pid_never_becomes_foreign_and_candidate_zero_counters_count(self):
        self.assertEqual(self.classify(b",bytes_in,bytes_out,\nname.42,0,0,\n").candidate_row_count, 1)
        self.assertEqual(self.classify(b",bytes_in,bytes_out,\nname.123,0,0,\n").unresolved_row_count, 1)

    def test_strict_tail_headers_ascii_counters_and_rows(self):
        for payload in (
            b"", b",bytes_in,bytes_out,", b"name.42,0,0,\n",
            b",bytes_in,bytes_out,\n\n", b",bytes_in,bytes_out,\n,,,\n",
            b",bytes_in,bytes_out,\r\nname.42,0,0,\n",
            b",bytes_in,bytes_out,\nname.0,0,0,\n", b",bytes_in,bytes_out,\nname.042,0,0,\n",
            b",bytes_in,bytes_out,\nname.42,-1,0,\n",
            b",bytes_in,bytes_out,\nname.42,18446744073709551616,0,\n",
            ",bytes_in,bytes_out,\nname.42,١,0,\n".encode(),
            b",bytes_in,bytes_out,\n\"unterminated.42,0,0,\n",
        ):
            with self.subTest(payload=payload[:80]), self.assertRaises(AuditInputError): self.classify(payload)

    def test_ambiguous_or_unbounded_pid_authority_rejected(self):
        for candidates, foreign in ((frozenset({42}), frozenset({42})), (frozenset(), frozenset()),
                                    (frozenset({True}), frozenset()), ({42}, frozenset())):
            with self.assertRaises(AuditInputError): self.classify(b",bytes_in,bytes_out,\n", candidates, foreign)

from Scripts.reconstruction.audit_installed_network_acquisition import (
    EXECUTION_REPORT_NAME,
    OBSERVATION_NAME,
    REPORT_NAME,
    AuditInputError,
    ContinuousMatrixObserverSession,
    ObserverExecution,
    ProcessIdentity,
    audit,
    audit_matrix_workload,
    matrix_observer_argv,
    observation_contains_workload,
    observer_argv,
    parse_observation,
)
from Scripts.reconstruction.write_execution_report import ExecutionReportError
from Scripts.reconstruction_gate_f.canonical_json import (
    canonical_sha256,
    load_canonical_json,
    write_canonical_json,
)
from Scripts.reconstruction_gate_f.command_catalog import (
    CommandExecutionMode,
    CommandHost,
    CommandMutationState,
    command_templates,
)
from Scripts.reconstruction_gate_f.command_compiler import (
    compile_command_plan,
    required_command_input_names,
)
from Scripts.reconstruction_gate_f.materialize_candidate_identity import (
    bundle_tree_digests,
)
from Scripts.reconstruction_gate_f.scenario_compiler import compile_scenario_catalog
from Scripts.reconstruction_gate_f.schema import EvidenceLayer, parse_candidate_identity
from Scripts.reconstruction_gate_f.receipt_validator import QualificationRunAuthority
from Scripts.reconstruction_gate_f.tests import candidate_mapping
from Scripts.ws24_emit_installed_qualification_report import (
    installed_selector_projection,
    load_installed_selector_catalog,
)


ROOT = Path(__file__).resolve().parents[2]
QUALIFICATION_RUN = QualificationRunAuthority(
    run_id="task11-installed-network-audit",
    nonce="e" * 64,
)
PREDECESSOR_OBSERVATIONS_SHA256 = "f" * 64


class ContinuousObserverTransportTests(unittest.TestCase):
    def setUp(self) -> None:
        self.children = []
        self.fd_count = len(os.listdir("/dev/fd"))
        self.real_popen = subprocess.Popen

    def tearDown(self) -> None:
        for child in self.children:
            if child.poll() is None:
                child.kill()
                child.wait(timeout=5)
            self.assertIsNotNone(child.poll())
        self.assertFalse(any(thread.name == "macscope-nettop-drain" for thread in threading.enumerate()))
        self.assertEqual(len(os.listdir("/dev/fd")), self.fd_count)

    def start(self, code: str):
        def spawn(*args, **kwargs):
            child = self.real_popen(*args, **kwargs)
            self.children.append(child)
            return child
        argv = (sys.executable, "-c", code)
        with mock.patch.object(network_audit, "matrix_observer_argv", return_value=argv), mock.patch.object(network_audit.subprocess, "Popen", side_effect=spawn):
            return network_audit.start_matrix_observer()

    def test_terminal_flushes_exact_header_before_child_exit(self) -> None:
        # No -u or explicit flush: tty stdout must cause producer line buffering.
        session = self.start("import sys,time; print(',bytes_in,bytes_out,'); time.sleep(30)")
        self.assertIsNone(self.children[0].poll())
        execution = session.finish()
        self.assertEqual(execution.stdout, network_audit.MATRIX_OBSERVER_READY_FRAME)
        self.assertEqual(execution.stderr, b"")
        self.assertTrue(execution.stopped_by_auditor)
        self.assertFalse(execution.timed_out)
        self.assertIsNotNone(execution.observer_eof_ns)
        self.assertLess(session.observer_spawn_ns, execution.observer_eof_ns)
        summary = network_audit.classify_matrix_observation(
            execution.stdout, candidate_pids=frozenset({4321}), foreign_pids=frozenset()
        )
        self.assertEqual(summary.sample_count, 1)
        self.assertEqual(summary.process_row_count, 0)

    def test_continuous_drain_prevents_backpressure(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            marker = Path(temporary) / "complete"
            code = (
                "import sys,time,pathlib; print(',bytes_in,bytes_out,'); "
                "sys.stdout.write('x'*262144); sys.stdout.flush(); "
                f"pathlib.Path({str(marker)!r}).touch(); time.sleep(30)"
            )
            session = self.start(code)
            try:
                deadline = time.monotonic() + 5
                while not marker.exists() and time.monotonic() < deadline:
                    time.sleep(0.01)
                self.assertTrue(marker.exists(), "producer blocked before finish drained output")
            finally:
                execution = session.finish()
            self.assertEqual(execution.stdout, network_audit.MATRIX_OBSERVER_READY_FRAME + b"x" * 262144)
            self.assertEqual(execution.stderr, b"")

    def test_malformed_stderr_early_exit_and_silence_refuse_readiness(self) -> None:
        cases = (
            "import time; print('wrong'); time.sleep(30)",
            "import sys,time; sys.stderr.write('refused\\n'); sys.stderr.flush(); time.sleep(30)",
            "pass",
            "import time; time.sleep(30)",
        )
        for code in cases:
            with self.subTest(code=code), mock.patch.object(network_audit, "MATRIX_OBSERVER_READY_TIMEOUT_SECONDS", 0.3):
                with self.assertRaises(AuditInputError):
                    self.start(code)

    def test_stdout_and_stderr_overflow_are_bounded_and_fail_closed(self) -> None:
        for stream in ("stdout", "stderr"):
            with self.subTest(stream=stream), tempfile.TemporaryDirectory() as temporary:
                trigger = Path(temporary) / "trigger"
                code = (
                    "import sys,time,pathlib\nprint(',bytes_in,bytes_out,')\n"
                    f"while not pathlib.Path({str(trigger)!r}).exists(): time.sleep(.01)\n"
                    f"sys.{stream}.write('x'*262144)\nsys.{stream}.flush()\ntime.sleep(30)"
                )
                with mock.patch.object(network_audit, "MAX_OBSERVER_STDOUT_BYTES", 4096), mock.patch.object(network_audit, "MAX_OBSERVER_STDERR_BYTES", 1024):
                    session = self.start(code)
                    trigger.touch()
                    try:
                        self.children[-1].wait(timeout=5)
                    finally:
                        execution = session.finish()
                    self.assertFalse(execution.stopped_by_auditor)
                    self.assertTrue(execution.stderr)
                    self.assertLessEqual(len(execution.stdout), 4097)
                    self.assertLessEqual(len(execution.stderr), 1025)

    def test_exit_after_readiness_is_not_auditor_owned_termination(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            trigger = Path(temporary) / "exit"
            session = self.start(
                "import time,pathlib\nprint(',bytes_in,bytes_out,')\n"
                f"while not pathlib.Path({str(trigger)!r}).exists(): time.sleep(.01)"
            )
            trigger.touch()
            self.children[-1].wait(timeout=5)
            execution = session.finish()
            self.assertFalse(execution.stopped_by_auditor)
            self.assertEqual(execution.returncode, 0)

    def test_retained_slave_after_child_exit_is_bounded_unavailable_evidence(self) -> None:
        retained = []
        def spawn(*args, **kwargs):
            retained.append(os.dup(kwargs["stdout"]))
            child = self.real_popen(*args, **kwargs)
            self.children.append(child)
            return child
        argv = (sys.executable, "-c", "import time; print(',bytes_in,bytes_out,'); time.sleep(30)")
        try:
            with mock.patch.object(network_audit, "matrix_observer_argv", return_value=argv), mock.patch.object(network_audit.subprocess, "Popen", side_effect=spawn):
                session = network_audit.start_matrix_observer()
            started = time.monotonic()
            execution = session.finish()
            self.assertLess(time.monotonic() - started, 5)
            self.assertIn(b"descriptors remained open", execution.stderr)
            self.assertFalse(execution.stopped_by_auditor)
        finally:
            for descriptor in retained:
                os.close(descriptor)

    def test_failed_thread_start_cleans_owned_process_and_descriptors(self) -> None:
        with mock.patch.object(network_audit.threading.Thread, "start", side_effect=RuntimeError("synthetic failure")):
            with self.assertRaisesRegex(AuditInputError, "cannot start continuous nettop drain"):
                self.start("import time; time.sleep(30)")

    def test_stdout_closure_while_child_lives_is_unavailable(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            trigger = Path(temporary) / "close"
            session = self.start(
                "import time,pathlib,os\nprint(',bytes_in,bytes_out,')\n"
                f"while not pathlib.Path({str(trigger)!r}).exists(): time.sleep(.01)\n"
                "os.close(1)\ntime.sleep(30)"
            )
            trigger.touch()
            try:
                self.children[-1].wait(timeout=5)
            finally:
                execution = session.finish()
            self.assertIn(b"closed stdout before auditor termination", execution.stderr)
            self.assertFalse(execution.stopped_by_auditor)

    def test_second_wait_failure_still_cleans_transport(self) -> None:
        session = self.start("import time; print(',bytes_in,bytes_out,'); time.sleep(30)")
        child = self.children[-1]
        real_wait = child.wait
        calls = 0
        def failing_wait(timeout):
            nonlocal calls
            calls += 1
            if calls == 2:
                real_wait(timeout=5)  # Reap the synthetic child, then inject the failure.
            raise subprocess.TimeoutExpired(child.args, timeout)
        with mock.patch.object(child, "wait", side_effect=failing_wait):
            with self.assertRaisesRegex(AuditInputError, "child did not exit within its cleanup bound"):
                session.finish()
        self.assertEqual(calls, 2)


class InstalledNetworkAcquisitionAuditTests(unittest.TestCase):
    def setUp(self) -> None:
        self.watch_queues = []
        def synthetic_watch(paths):
            queue = Queue()
            self.watch_queues.append(queue)
            return ProcessWatchCollector(paths, queue_factory=lambda: queue, event_factory=registration_event)
        patcher = mock.patch.object(network_audit, "ProcessWatchCollector", side_effect=synthetic_watch)
        patcher.start(); self.addCleanup(patcher.stop)
        census = mock.patch.object(network_audit, "_all_process_ids", return_value=())
        census.start(); self.addCleanup(census.stop)
        self.temporary = tempfile.TemporaryDirectory(
            prefix="macscope-network-audit-",
        )
        self.root = Path(self.temporary.name).resolve()
        self.app = self.root / "MacScope.app"
        contents = self.app / "Contents"
        executable = contents / "MacOS" / "MacScope"
        executable.parent.mkdir(parents=True)
        executable.write_bytes(b"candidate executable\n")
        executable.chmod(0o755)
        import plistlib

        with (contents / "Info.plist").open("wb") as stream:
            plistlib.dump(
                {
                    "CFBundleIdentifier": "org.macscope.app",
                    "CFBundleExecutable": "MacScope",
                },
                stream,
            )
        self.executable = executable.resolve()
        mapping = candidate_mapping()
        mapping["application"]["executable_sha256"] = hashlib.sha256(
            executable.read_bytes()
        ).hexdigest()
        digests = bundle_tree_digests(self.app)
        mapping["application"]["bundle_sha256"] = digests.content_sha256
        mapping["application"]["closed_tree_sha256"] = digests.closed_tree_sha256
        mapping["application"]["root_mode"] = self.app.stat().st_mode & 0o7777
        self.candidate_path = self.root / "candidate.json"
        write_canonical_json(self.candidate_path, mapping)
        candidate, issues = parse_candidate_identity(mapping)
        self.assertFalse(issues)
        self.assertIsNotNone(candidate)
        self.candidate = candidate
        self.tool = self.root / "nettop"
        self.tool.write_bytes(b"fixture observer\n")
        self.tool.chmod(0o755)
        self.pid = 4242
        self.identity = ProcessIdentity(
            pid=self.pid,
            executable_path=str(self.executable),
            start_time_unix_us=1_700_000_000_123_456,
        )

    def tearDown(self) -> None:
        self.assertTrue(all(queue.closed for queue in self.watch_queues))
        self.temporary.cleanup()

    @staticmethod
    def framed_output(
        sample_count: int,
        *,
        process_row: str | None = None,
    ) -> bytes:
        lines: list[str] = []
        for index in range(sample_count):
            lines.append(",bytes_in,bytes_out,")
            if index == 1 and process_row is not None:
                lines.append(process_row)
        return ("\n".join(lines) + "\n").encode("utf-8")

    def provider(self, _: str) -> tuple[ProcessIdentity, ...]:
        return (self.identity,)

    def observer(
        self,
        stdout: bytes,
        *,
        returncode: int = 0,
        stderr: bytes = b"",
        elapsed_ms: int = 2_000,
        timed_out: bool = False,
    ):
        def run(pid: int, duration_seconds: int):
            return observer_argv(pid, duration_seconds), ObserverExecution(
                returncode=returncode,
                stdout=stdout,
                stderr=stderr,
                elapsed_ms=elapsed_ms,
                timed_out=timed_out,
            )

        return run

    def run_audit(self, observer, *, provider=None, suffix="evidence"):
        return audit(
            candidate_identity_path=self.candidate_path,
            app_bundle=self.app,
            duration_seconds=2,
            artifact_root=self.root / suffix,
            qualification_run=QUALIFICATION_RUN,
            predecessor_observations_sha256=PREDECESSOR_OBSERVATIONS_SHA256,
            process_provider=self.provider if provider is None else provider,
            observer_runner=observer,
            observer_tool_path=self.tool,
        )

    def test_rejects_modified_installed_bundle_with_same_executable(self) -> None:
        (self.app / "Contents/Resources").mkdir()
        (self.app / "Contents/Resources/substituted.txt").write_text(
            "not candidate content\n",
            encoding="utf-8",
        )

        with self.assertRaisesRegex(AuditInputError, "bundle"):
            self.run_audit(
                self.observer(self.framed_output(3)),
                suffix="modified-bundle",
            )

    def test_rejects_installed_bundle_mutation_during_observation(self) -> None:
        def mutate_bundle(pid: int, duration_seconds: int):
            resources = self.app / "Contents/Resources"
            resources.mkdir()
            (resources / "late-substitution.txt").write_text(
                "changed during observation\n",
                encoding="utf-8",
            )
            return observer_argv(pid, duration_seconds), ObserverExecution(
                returncode=0,
                stdout=self.framed_output(3),
                stderr=b"",
                elapsed_ms=2_000,
            )

        report, exit_code = self.run_audit(
            mutate_bundle,
            suffix="mutated-during-observation",
        )

        self.assertEqual(exit_code, 1)
        self.assertIn("bundle", str(report["diagnostic"]))

    def matrix_fixture(self):
        mapping = candidate_mapping()
        mapping["application"]["executable_sha256"] = hashlib.sha256(
            self.executable.read_bytes()
        ).hexdigest()
        names = {
            "ai-agent-worker": "AIAgentWorkerXPCService",
            "analysis-worker": "AnalysisWorkerXPCService",
            "native-decompiler": "NativeDecompilerXPCService",
            "shell-broker": "ShellBrokerXPCService",
        }
        identities: dict[str, ProcessIdentity] = {
            str(self.executable): self.identity,
        }
        for index, (identity_id, name) in enumerate(sorted(names.items()), start=1):
            executable = (
                self.app / "Contents/XPCServices" / f"{name}.xpc/Contents/MacOS" / name
            )
            executable.parent.mkdir(parents=True)
            executable.write_bytes(f"{identity_id}\n".encode())
            executable.chmod(0o755)
            digest = hashlib.sha256(executable.read_bytes()).hexdigest()
            next(
                item
                for item in mapping["application"]["embedded_executables"]
                if item["identity_id"] == identity_id
            )["sha256"] = digest
            identities[str(executable.resolve())] = ProcessIdentity(
                self.pid + index,
                str(executable.resolve()),
                self.identity.start_time_unix_us + index,
            )
        digests = bundle_tree_digests(self.app)
        mapping["application"]["bundle_sha256"] = digests.content_sha256
        mapping["application"]["closed_tree_sha256"] = digests.closed_tree_sha256
        mapping["application"]["root_mode"] = self.app.stat().st_mode & 0o7777
        write_canonical_json(self.candidate_path, mapping)
        return identities

    @staticmethod
    def matrix_evidence() -> dict[str, object]:
        selector_projection = installed_selector_projection(
            load_installed_selector_catalog()
        )
        return {
            "matrix_receipt_sha256": "1" * 64,
            "xcresult_bundle_sha256": "2" * 64,
            "xcresult_closed_tree_sha256": "3" * 64,
            "xcresult_semantic_manifest_sha256": "5" * 64,
            "selector_catalog_sha256": "4" * 64,
            "selector_projection_sha256": canonical_sha256(selector_projection),
            "expected_selector_count": 22,
            "executed_selector_count": 22,
            "passed_selector_count": 22,
            "failed_selector_count": 0,
            "skipped_selector_count": 0,
            "matrix_result": "passed",
        }

    @staticmethod
    def continuous_observer(
        stdout: bytes,
        *,
        returncode: int = 0,
        stopped_by_auditor: bool = True,
    ):
        """A single-session fixture; each call represents one sealed interval."""

        def start() -> ContinuousMatrixObserverSession:
            now = time.time_ns() // 1_000_000
            return ContinuousMatrixObserverSession(
                matrix_observer_argv(),
                now,
                now,
                hashlib.sha256(b",bytes_in,bytes_out,\n").hexdigest(),
                lambda: ObserverExecution(
                    returncode,
                    stdout,
                    b"",
                    25,
                    stopped_by_auditor=stopped_by_auditor,
                    observer_eof_ns=time.monotonic_ns(),
                ),
                observer_spawn_ns=time.monotonic_ns(),
            )

        return start

    def test_matrix_observation_contains_workload_and_complete_candidate_process_set(self) -> None:
        self.assertTrue(observation_contains_workload(10, 11, 19, 20))
        self.assertFalse(observation_contains_workload(12, 11, 19, 20))
        self.assertFalse(observation_contains_workload(10, 11, 21, 20))
        self.assertFalse(observation_contains_workload(10, 11, 11, 20))
        identities = self.matrix_fixture()

        def provider(path: str) -> tuple[ProcessIdentity, ...]:
            return (identities[path],)

        original_umask = os.umask(0o000)
        try:
            value, report, exit_code = audit_matrix_workload(
                candidate_identity_path=self.candidate_path,
                app_bundle=self.app,
                artifact_root=self.root / "matrix-evidence",
                qualification_run=QUALIFICATION_RUN,
                predecessor_observations_sha256=PREDECESSOR_OBSERVATIONS_SHA256,
                workload=lambda: (
                    (time.sleep(0.02), "matrix-complete")[1],
                    self.matrix_evidence(),
                ),
                process_provider=provider,
                observer_session_factory=self.continuous_observer(
                    b",bytes_in,bytes_out,\n"
                ),
                observer_tool_path=self.tool,
            )
        finally:
            os.umask(original_umask)
        self.assertEqual(value, "matrix-complete")
        self.assertEqual(exit_code, 0)
        self.assertTrue(report["workload"]["observation_contains_workload"])
        self.assertTrue(report["workload"]["observer_readiness_precedes_workload"])
        self.assertEqual(
            {item["identity_id"] for item in report["executables"]},
            {"app", "ai-agent-worker", "analysis-worker", "native-decompiler", "shell-broker"},
        )
        self.assertTrue(all(item["processes"] for item in report["executables"]))
        self.assertEqual(report["observer"]["observer_invocation_count"], 1)
        self.assertTrue(report["observer"]["readiness_proven"])
        self.assertEqual(
            report["observer"]["readiness_frame_sha256"],
            hashlib.sha256(b",bytes_in,bytes_out,\n").hexdigest(),
        )
        self.assertTrue(report["observer"]["continuity_proven"])
        self.assertTrue(report["observer"]["stopped_by_auditor"])
        observation = (self.root / "matrix-evidence" / OBSERVATION_NAME).read_bytes()
        self.assertEqual(
            report["observer"]["observation_sha256"],
            hashlib.sha256(observation).hexdigest(),
        )
        artifact_root = self.root / "matrix-evidence"
        self.assertEqual(artifact_root.stat().st_mode & 0o777, 0o700)
        self.assertEqual(
            sorted(path.name for path in artifact_root.iterdir()),
            sorted((REPORT_NAME, EXECUTION_REPORT_NAME, OBSERVATION_NAME)),
        )
        for name in (REPORT_NAME, EXECUTION_REPORT_NAME, OBSERVATION_NAME):
            with self.subTest(artifact=name):
                metadata = (artifact_root / name).stat()
                self.assertEqual(metadata.st_mode & 0o777, 0o600)
                self.assertEqual(metadata.st_nlink, 1)
        for name in (REPORT_NAME, EXECUTION_REPORT_NAME):
            with self.subTest(canonical_json=name):
                path = artifact_root / name
                self.assertIsInstance(load_canonical_json(path), dict)
                self.assertFalse(path.read_bytes().endswith(b"\n"))

    def test_matrix_json_publication_rejects_existing_files_and_symlinks_without_replacement(
        self,
    ) -> None:
        identities = self.matrix_fixture()
        cases = (
            (EXECUTION_REPORT_NAME, "existing"),
            (EXECUTION_REPORT_NAME, "symlink"),
            (REPORT_NAME, "existing"),
            (REPORT_NAME, "symlink"),
        )
        for index, (filename, attack) in enumerate(cases):
            with self.subTest(filename=filename, attack=attack):
                artifact_root = self.root / f"matrix-publication-attack-{index}"
                foreign = self.root / f"foreign-publication-target-{index}.json"
                foreign.write_bytes(b"foreign artifact bytes")
                attacked_path = artifact_root / filename
                attacked_inode = 0

                def workload() -> tuple[str, dict[str, object]]:
                    nonlocal attacked_inode
                    if attack == "existing":
                        attacked_path.write_bytes(b"pre-existing artifact bytes")
                    else:
                        attacked_path.symlink_to(foreign)
                    attacked_inode = attacked_path.lstat().st_ino
                    return "matrix-complete", self.matrix_evidence()

                with self.assertRaisesRegex(
                    ExecutionReportError,
                    "absent absolute path",
                ):
                    audit_matrix_workload(
                        candidate_identity_path=self.candidate_path,
                        app_bundle=self.app,
                        artifact_root=artifact_root,
                        qualification_run=QUALIFICATION_RUN,
                        predecessor_observations_sha256=(
                            PREDECESSOR_OBSERVATIONS_SHA256
                        ),
                        workload=workload,
                        process_provider=lambda path: (identities[path],),
                        observer_session_factory=self.continuous_observer(
                            b",bytes_in,bytes_out,\n"
                        ),
                        observer_tool_path=self.tool,
                    )
                self.assertEqual(attacked_path.lstat().st_ino, attacked_inode)
                if attack == "existing":
                    self.assertFalse(attacked_path.is_symlink())
                    self.assertEqual(
                        attacked_path.read_bytes(),
                        b"pre-existing artifact bytes",
                    )
                else:
                    self.assertTrue(attacked_path.is_symlink())
                self.assertEqual(foreign.read_bytes(), b"foreign artifact bytes")

    def test_matrix_observation_accepts_task_owned_relaunch_and_rejects_pid_reuse(self) -> None:
        identities = self.matrix_fixture()
        calls_by_path: dict[str, int] = {}

        def relaunched_provider(path: str) -> tuple[ProcessIdentity, ...]:
            calls_by_path[path] = calls_by_path.get(path, 0) + 1
            identity = identities[path]
            if path == str(self.executable) and calls_by_path[path] > 1:
                return (
                    ProcessIdentity(
                        identity.pid + 100,
                        identity.executable_path,
                        identity.start_time_unix_us + 100,
                    ),
                )
            return (identity,)

        _, relaunched, relaunched_exit = audit_matrix_workload(
            candidate_identity_path=self.candidate_path,
            app_bundle=self.app,
            artifact_root=self.root / "matrix-relaunched",
            qualification_run=QUALIFICATION_RUN,
            predecessor_observations_sha256=PREDECESSOR_OBSERVATIONS_SHA256,
            workload=lambda: (time.sleep(0.02), self.matrix_evidence()),
            process_provider=relaunched_provider,
            observer_session_factory=self.continuous_observer(
                b",bytes_in,bytes_out,\n"
            ),
            observer_tool_path=self.tool,
        )
        self.assertEqual(relaunched_exit, 0)
        app_processes = next(
            item["processes"] for item in relaunched["executables"]
            if item["identity_id"] == "app"
        )
        self.assertEqual(
            {(item["pid"], item["start_time_unix_us"]) for item in app_processes},
            {
                (self.identity.pid, self.identity.start_time_unix_us),
                (self.identity.pid + 100, self.identity.start_time_unix_us + 100),
            },
        )

        calls = 0
        def reused_provider(path: str) -> tuple[ProcessIdentity, ...]:
            nonlocal calls
            identity = identities[path]
            if path == str(self.executable):
                calls += 1
                if calls > 1:
                    identity = ProcessIdentity(
                        identity.pid, identity.executable_path, identity.start_time_unix_us + 1
                    )
            return (identity,)

        _, reused, reused_exit = audit_matrix_workload(
            candidate_identity_path=self.candidate_path,
            app_bundle=self.app,
            artifact_root=self.root / "matrix-reused",
            qualification_run=QUALIFICATION_RUN,
            predecessor_observations_sha256=PREDECESSOR_OBSERVATIONS_SHA256,
            workload=lambda: (time.sleep(0.2), self.matrix_evidence()),
            process_provider=reused_provider,
            observer_session_factory=self.continuous_observer(
                b",bytes_in,bytes_out,\n"
            ),
            observer_tool_path=self.tool,
        )
        self.assertEqual(reused_exit, 1)
        self.assertIn("PID was reused", reused["diagnostic"])

    def test_continuous_matrix_observation_rejects_short_lived_connection_between_legacy_sample_gaps(self) -> None:
        """A non-loopback row between otherwise empty frames must fail the run.

        The mutation is the middle row: deleting it models the old point-sample
        blind spot, while the one continuous observer session must retain it.
        """
        identities = self.matrix_fixture()
        starts = 0

        def start() -> ContinuousMatrixObserverSession:
            nonlocal starts
            starts += 1
            now = time.time_ns() // 1_000_000
            return ContinuousMatrixObserverSession(
                matrix_observer_argv(),
                now,
                now,
                hashlib.sha256(b",bytes_in,bytes_out,\n").hexdigest(),
                lambda: ObserverExecution(
                    0,
                    (
                        b",bytes_in,bytes_out,\n"
                        + f"MacScope.{self.pid},1,1,\n".encode()
                        + b",bytes_in,bytes_out,\n"
                    ),
                    b"",
                    25,
                    stopped_by_auditor=True,
                    observer_eof_ns=time.monotonic_ns(),
                ),
                observer_spawn_ns=time.monotonic_ns(),
            )

        _, report, exit_code = audit_matrix_workload(
            candidate_identity_path=self.candidate_path,
            app_bundle=self.app,
            artifact_root=self.root / "matrix-short-lived-connection",
            qualification_run=QUALIFICATION_RUN,
            predecessor_observations_sha256=PREDECESSOR_OBSERVATIONS_SHA256,
            workload=lambda: ("matrix-complete", self.matrix_evidence()),
            process_provider=lambda path: (identities[path],),
            observer_session_factory=start,
            observer_tool_path=self.tool,
        )
        self.assertEqual(starts, 1)
        self.assertEqual(exit_code, 1)
        self.assertEqual(report["result"], "failed")
        self.assertIn("non-loopback", report["diagnostic"])

    def test_matrix_observation_rejects_foreign_or_unattributable_process_events(self) -> None:
        identities = self.matrix_fixture()
        _, report, exit_code = audit_matrix_workload(
            candidate_identity_path=self.candidate_path,
            app_bundle=self.app,
            artifact_root=self.root / "matrix-foreign-event",
            qualification_run=QUALIFICATION_RUN,
            predecessor_observations_sha256=PREDECESSOR_OBSERVATIONS_SHA256,
            workload=lambda: ("matrix-complete", self.matrix_evidence()),
            process_provider=lambda path: (identities[path],),
            observer_session_factory=self.continuous_observer(
                b",bytes_in,bytes_out,\nforeign.9001,1,1,\n"
            ),
            observer_tool_path=self.tool,
        )
        self.assertEqual(exit_code, 1)
        self.assertEqual(report["result"], "unavailable")
        self.assertIn("without prearmed foreign or exact candidate authority", report["diagnostic"])

    def attributed_matrix(self, *, queue=None, workload=None, observer=None, maximum_report=None):
        identities = self.matrix_fixture()
        foreign = self.root / "foreign-executable"
        foreign.write_bytes(b"foreign")
        queue = queue or Queue()
        self.watch_queues.append(queue)
        def factory(paths):
            return ProcessWatchCollector(paths, queue_factory=lambda: queue, event_factory=registration_event,
                                         path_probe=lambda pid: str(foreign))
        payload = b",bytes_in,bytes_out,\nMacScope.9001,3,2,\n"
        with mock.patch.object(network_audit, "MAX_MATRIX_REPORT_BYTES", maximum_report or 4 * 1024 * 1024):
            result = audit_matrix_workload(
                candidate_identity_path=self.candidate_path, app_bundle=self.app,
                artifact_root=self.root / "attributed", qualification_run=QUALIFICATION_RUN,
                predecessor_observations_sha256=PREDECESSOR_OBSERVATIONS_SHA256,
                workload=workload or (lambda: ((time.sleep(0.02), "done")[1], self.matrix_evidence())),
                process_provider=lambda path: (identities[path],),
                observer_session_factory=observer or self.continuous_observer(payload),
                observer_tool_path=self.tool, watch_collector_factory=factory, pid_census=lambda: (9001,),
            )
        return result, payload

    def test_stable_prearmed_foreign_row_passes_and_all_raw_bytes_are_retained(self):
        (_, report, code), payload = self.attributed_matrix()
        self.assertEqual(code, 0, report["diagnostic"])
        self.assertEqual(report["schema_version"], 4)
        self.assertEqual(report["observer"]["observed_process_row_count"], 1)
        self.assertEqual(report["observer"]["observed_foreign_row_count"], 1)
        self.assertEqual(report["observer"]["observed_unresolved_row_count"], 0)
        self.assertEqual(report["observer"]["limitations"], list(network_audit.MATRIX_LIMITATIONS))
        self.assertEqual((self.root / "attributed" / OBSERVATION_NAME).read_bytes(), payload)
        self.assertEqual(report["attribution"]["proofs"][0]["pid"], 9001)
        self.assertNotIn("start_time_unix_us", str(report["attribution"]))

    def test_transition_during_workload_retained_and_row_becomes_unresolved(self):
        queue = Queue()
        def workload():
            queue.batches = [[event(pid=9001)], []]
            time.sleep(0.02)
            return "done", self.matrix_evidence()
        (_, report, code), _ = self.attributed_matrix(queue=queue, workload=workload)
        self.assertEqual(code, 1)
        self.assertEqual(report["result"], "unavailable")
        self.assertEqual(report["observer"]["observed_unresolved_row_count"], 1)
        self.assertTrue(report["attribution"]["drains"][1]["events"])
        self.assertEqual(report["attribution"]["proofs"], [])

    def test_whole_serialized_report_bound_refuses_publication_not_truncation(self):
        with self.assertRaisesRegex(AuditInputError, "whole network audit report"):
            self.attributed_matrix(maximum_report=100)
        self.assertFalse((self.root / "attributed" / REPORT_NAME).exists())
        self.assertTrue((self.root / "attributed" / OBSERVATION_NAME).exists())

    def test_missing_actual_eof_cannot_be_substituted_with_finish_time(self):
        original = self.continuous_observer(b",bytes_in,bytes_out,\n")
        def start():
            session = original()
            return ContinuousMatrixObserverSession(
                session.argv, session.started_at_unix_ms, session.ready_at_unix_ms,
                session.readiness_frame_sha256,
                lambda: ObserverExecution(0, b",bytes_in,bytes_out,\n", b"", 25, stopped_by_auditor=True),
                session.observer_spawn_ns,
            )
        (_, report, code), _ = self.attributed_matrix(observer=start)
        self.assertEqual(code, 1)
        self.assertEqual(report["result"], "unavailable")
        self.assertIsNone(report["attribution"]["observer_eof_ns"])

    def test_callback_exception_closes_observer_and_watch_once(self):
        finishes = []
        original = self.continuous_observer(b",bytes_in,bytes_out,\n")
        def start():
            session = original()
            def finish():
                finishes.append(1)
                return session.finish()
            return ContinuousMatrixObserverSession(session.argv, session.started_at_unix_ms,
                session.ready_at_unix_ms, session.readiness_frame_sha256, finish, session.observer_spawn_ns)
        def fail(): raise RuntimeError("callback failed")
        with self.assertRaisesRegex(RuntimeError, "callback failed"):
            self.attributed_matrix(workload=fail, observer=start)
        self.assertEqual(finishes, [1])

    def test_observer_start_failure_closes_watch_before_propagation(self):
        def fail(): raise AuditInputError("observer startup failed")
        with self.assertRaisesRegex(AuditInputError, "startup failed"):
            self.attributed_matrix(observer=fail)

    def test_matrix_observation_rejects_an_observer_that_exited_zero_before_finish(self) -> None:
        """A successful process exit is not evidence of continuous coverage."""

        identities = self.matrix_fixture()
        _, report, exit_code = audit_matrix_workload(
            candidate_identity_path=self.candidate_path,
            app_bundle=self.app,
            artifact_root=self.root / "matrix-observer-early-zero-exit",
            qualification_run=QUALIFICATION_RUN,
            predecessor_observations_sha256=PREDECESSOR_OBSERVATIONS_SHA256,
            workload=lambda: ("matrix-complete", self.matrix_evidence()),
            process_provider=lambda path: (identities[path],),
            observer_session_factory=self.continuous_observer(
                b",bytes_in,bytes_out,\n",
                stopped_by_auditor=False,
            ),
            observer_tool_path=self.tool,
        )
        self.assertEqual(exit_code, 1)
        self.assertEqual(report["result"], "unavailable")
        self.assertFalse(report["observer"]["stopped_by_auditor"])
        self.assertFalse(report["observer"]["continuity_proven"])
        self.assertIn("exited before the workload closed", report["diagnostic"])

    def test_matrix_observer_readiness_must_be_attested_before_workload(self) -> None:
        identities = self.matrix_fixture()
        workload_called = False

        def not_ready() -> ContinuousMatrixObserverSession:
            now = time.time_ns() // 1_000_000
            return ContinuousMatrixObserverSession(
                matrix_observer_argv(),
                now,
                now,
                "0" * 64,
                lambda: ObserverExecution(0, b",bytes_in,bytes_out,\n", b"", 25),
            )

        def workload() -> tuple[str, dict[str, object]]:
            nonlocal workload_called
            workload_called = True
            return "matrix-complete", self.matrix_evidence()

        with self.assertRaisesRegex(AuditInputError, "readiness is not attested"):
            audit_matrix_workload(
                candidate_identity_path=self.candidate_path,
                app_bundle=self.app,
                artifact_root=self.root / "matrix-not-ready",
                qualification_run=QUALIFICATION_RUN,
                predecessor_observations_sha256=PREDECESSOR_OBSERVATIONS_SHA256,
                workload=workload,
                process_provider=lambda path: (identities[path],),
                observer_session_factory=not_ready,
                observer_tool_path=self.tool,
            )
        self.assertFalse(workload_called)

    def test_zero_acquisition_requires_complete_available_observation(self) -> None:
        stdout = self.framed_output(3)
        report, exit_code = self.run_audit(self.observer(stdout))
        self.assertEqual(exit_code, 0)
        self.assertEqual(report["result"], "passed")
        self.assertIsNone(report["diagnostic"])
        self.assertEqual(report["process"]["pid"], self.pid)
        self.assertEqual(
            report["app"]["executable_sha256"],
            hashlib.sha256(self.executable.read_bytes()).hexdigest(),
        )
        self.assertEqual(report["observer"]["availability"], "available")
        self.assertEqual(report["observer"]["observed_sample_count"], 3)
        self.assertEqual(report["observer"]["observed_process_row_count"], 0)
        artifact_root = self.root / "evidence"
        self.assertEqual((artifact_root / OBSERVATION_NAME).read_bytes(), stdout)
        self.assertEqual(
            load_canonical_json(artifact_root / REPORT_NAME),
            report,
        )
        execution_report = load_canonical_json(artifact_root / EXECUTION_REPORT_NAME)
        self.assertEqual(
            set(execution_report),
            {
                "schema_version",
                "started_at_unix_ms",
                "ended_at_unix_ms",
                "result",
                "exit_code",
                "qualification_run",
                "predecessor_observations_sha256",
                "stress",
            },
        )
        self.assertEqual(execution_report["schema_version"], 2)
        self.assertEqual(
            execution_report["qualification_run"],
            {"run_id": QUALIFICATION_RUN.run_id, "nonce": QUALIFICATION_RUN.nonce},
        )
        self.assertEqual(
            execution_report["predecessor_observations_sha256"],
            PREDECESSOR_OBSERVATIONS_SHA256,
        )
        self.assertEqual(execution_report["result"], "passed")
        self.assertEqual(execution_report["exit_code"], 0)
        self.assertEqual(report["command_id"], "installed.network-acquisition-audit")
        self.assertEqual(report["candidate"]["source_commit"], self.candidate.source.commit)
        self.assertEqual(report["candidate"]["source_tree"], self.candidate.source.tree)
        self.assertEqual(
            report["artifacts"][0]["sha256"],
            hashlib.sha256(stdout).hexdigest(),
        )

    def test_nonloopback_process_row_is_a_qualification_failure(self) -> None:
        stdout = self.framed_output(3, process_row=f"MacScope.{self.pid},1,0,")
        report, exit_code = self.run_audit(
            self.observer(stdout),
            suffix="observed",
        )
        self.assertEqual(exit_code, 1)
        self.assertEqual(report["result"], "failed")
        self.assertEqual(report["observer"]["availability"], "available")
        self.assertEqual(report["observer"]["observed_process_row_count"], 1)
        self.assertIn("non-loopback", report["diagnostic"])

    def test_observer_unavailability_cannot_be_reported_as_passed(self) -> None:
        def wrong_vector(pid: int, duration_seconds: int):
            return ("/usr/bin/nettop", "-h"), ObserverExecution(
                returncode=0,
                stdout=self.framed_output(duration_seconds + 1),
                stderr=b"",
                elapsed_ms=duration_seconds * 1_000,
            )

        cases = (
            (self.observer(b"", returncode=1), "nonzero"),
            (self.observer(b""), "empty"),
            (
                self.observer(self.framed_output(3), timed_out=True, returncode=124),
                "timeout",
            ),
            (
                self.observer(self.framed_output(3), stderr=b"observer warning\n"),
                "stderr",
            ),
            (self.observer(self.framed_output(2)), "truncated"),
            (self.observer(self.framed_output(3), elapsed_ms=10), "short"),
            (wrong_vector, "wrong-vector"),
        )
        for observer, suffix in cases:
            with self.subTest(case=suffix):
                report, exit_code = self.run_audit(observer, suffix=suffix)
                self.assertEqual(exit_code, 1)
                self.assertEqual(report["result"], "unavailable")
                self.assertEqual(report["observer"]["availability"], "unavailable")
                self.assertIsNotNone(report["diagnostic"])
                execution_report = load_canonical_json(
                    self.root / suffix / EXECUTION_REPORT_NAME
                )
                self.assertEqual(execution_report["result"], "unavailable")
                self.assertIsNone(execution_report["exit_code"])

    def test_process_identity_must_survive_the_whole_window(self) -> None:
        calls = 0

        def provider(_: str) -> tuple[ProcessIdentity, ...]:
            nonlocal calls
            calls += 1
            if calls == 1:
                return (self.identity,)
            return (
                ProcessIdentity(
                    pid=self.pid,
                    executable_path=str(self.executable),
                    start_time_unix_us=self.identity.start_time_unix_us + 1,
                ),
            )

        report, exit_code = self.run_audit(
            self.observer(self.framed_output(3)),
            provider=provider,
            suffix="pid-reuse",
        )
        self.assertEqual(exit_code, 1)
        self.assertEqual(report["result"], "unavailable")
        self.assertIn("identity changed", report["diagnostic"])

    def test_missing_duplicate_or_wrong_executable_process_is_rejected_before_observation(self) -> None:
        providers = (
            lambda _: (),
            lambda _: (self.identity, self.identity),
            lambda _: (
                ProcessIdentity(self.pid, "/private/tmp/not-macscope", 1),
            ),
        )
        for index, provider in enumerate(providers):
            with self.subTest(case=index):
                with self.assertRaises(AuditInputError):
                    self.run_audit(
                        self.observer(self.framed_output(3)),
                        provider=provider,
                        suffix=f"bad-process-{index}",
                    )

    def test_candidate_executable_drift_is_rejected(self) -> None:
        self.executable.write_bytes(b"drifted\n")
        with self.assertRaisesRegex(AuditInputError, "SHA-256 differs"):
            self.run_audit(
                self.observer(self.framed_output(3)),
                suffix="drifted",
            )

    def test_parser_rejects_foreign_pid_or_malformed_byte_counters(self) -> None:
        with self.assertRaisesRegex(AuditInputError, "another PID"):
            parse_observation(
                self.framed_output(3, process_row="MacScope.9999,1,0,"),
                pid=self.pid,
            )
        with self.assertRaisesRegex(AuditInputError, "byte counters"):
            parse_observation(
                self.framed_output(
                    3,
                    process_row=f"MacScope.{self.pid},not-a-number,0,",
                ),
                pid=self.pid,
            )

    def test_observer_vector_is_read_only_and_excludes_loopback(self) -> None:
        argv = observer_argv(self.pid, 30)
        self.assertEqual(argv[0], "/usr/bin/nettop")
        self.assertEqual(argv[argv.index("-p") + 1], str(self.pid))
        self.assertEqual(argv.count("-t"), 2)
        self.assertIn("external", argv)
        self.assertIn("undefined", argv)
        self.assertNotIn("loopback", argv)
        forbidden = {
            "curl",
            "wget",
            "nc",
            "open",
            "kill",
            "launchctl",
            "tccutil",
        }
        self.assertTrue(forbidden.isdisjoint(argv))

    def test_gate_f_command_is_exact_runnable_and_read_only_to_the_installed_product(self) -> None:
        values = {
            name: f"/private/tmp/macscope-gate-f/{name}"
            for name in required_command_input_names()
        }
        values.update(
            {
                "repository_root": str(ROOT),
                "native_source_root": str(ROOT / "Tools" / "NativeDecompilerBridge"),
                "native_wrapper_revision": "a" * 64,
                "integration_ref": "refs/heads/feature/reconstruction-r1-task10",
                "sdk_name": "macosx27.0",
                "generated_at_unix_ms": "0",
                "installed_app": "/Applications/MacScope.app",
                "source_release_app": "/private/tmp/macscope-gate-f/release/MacScope.app",
                "developer_dir": "/Applications/Xcode-beta.app/Contents/Developer",
                "qualification_run_id": "task11-installed-network-audit",
                "qualification_run_nonce": "a" * 64,
            }
        )
        for name in required_command_input_names():
            if name.endswith("predecessor_observations_sha256"):
                values[name] = "b" * 64
        scenarios = compile_scenario_catalog(self.candidate)
        plan = compile_command_plan(
            self.candidate,
            scenarios,
            repository_root=ROOT,
            inputs=values,
        )
        self.assertNotIn(
            "installed.network-acquisition-audit",
            {item.command_id for item in plan.commands},
        )
        record = next(
            item for item in plan.commands if item.command_id == "installed.task10-workflow"
        )
        self.assertEqual(record.execution_mode, CommandExecutionMode.RUNNABLE)
        self.assertEqual(record.host, CommandHost.MACOS_ARM64_XCODE27_TCC)
        self.assertEqual(record.evidence_layer, EvidenceLayer.INSTALLED_WORKFLOW)
        self.assertEqual(record.mutation_state, CommandMutationState.INSTALL_STATE)
        self.assertEqual(
            record.argv[record.argv.index("--network-artifact-root") + 1],
            values["installed_network_audit_artifact_root"],
        )
        self.assertEqual(
            record.argv[record.argv.index("--xcresult-semantic-manifest") + 1],
            values["installed_matrix_xcresult_semantic_manifest"],
        )
        self.assertEqual(
            set(record.command_groups),
            {"installed-network-audit", "installed-task10"},
        )
        self.assertEqual(
            set(record.generated_artifacts),
            {
                values["installed_network_audit_artifact_root"]
                + "/InstalledNetworkAcquisition.execution-report.json",
                values["installed_network_audit_artifact_root"]
                + "/InstalledNetworkAcquisition.audit.json",
                values["installed_network_audit_artifact_root"]
                + "/InstalledNetworkAcquisition.nettop.csv",
                values["installed_matrix_receipt"],
                values["installed_matrix_xcresult_semantic_manifest"],
                "stdout-json:installed-task10-matrix-summary",
            },
        )
        self.assertNotIn(EvidenceLayer.INSTALLED_WORKFLOW, plan.executor_required_layers)

    def test_source_has_no_network_generator_or_process_mutator(self) -> None:
        source = (
            ROOT / "Scripts/reconstruction/audit_installed_network_acquisition.py"
        ).read_text(encoding="utf-8")
        self.assertNotIn("import socket", source)
        self.assertNotIn("urllib.request", source)
        self.assertNotIn("requests.", source)
        self.assertNotIn("tccutil", source)
        self.assertNotIn("os.kill", source)
        # The matrix audit owns exactly one controlled process-launch seam: a
        # continuous CSV ``nettop`` session.  Its all-process argv is frozen
        # because Task10 deliberately relaunches the candidate; readiness is
        # independently attested before the workload starts.  Arbitrary
        # shell/process launch remains prohibited.
        self.assertEqual(source.count("subprocess.Popen("), 1)
        self.assertIn("argv = matrix_observer_argv()", source)
        self.assertIn("process = subprocess.Popen(\n            argv,", source)
        self.assertIn(
            "if session.argv != matrix_observer_argv():",
            source,
        )
        self.assertIn("_await_matrix_observer_readiness(collector)", source)
        self.assertNotIn('argv.extend(("-p", str(pid)))', source)
        self.assertNotIn("shell=True", source)
        self.assertNotIn("shell = True", source)


if __name__ == "__main__":
    unittest.main()
