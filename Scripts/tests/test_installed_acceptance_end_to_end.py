from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import time
from types import SimpleNamespace
import unittest
from unittest import mock

from Scripts.tests.installed_acceptance_host_fixture import macos_interpreter_files
from Scripts.reconstruction.network_process_watch import ProcessWatchCollector
from Scripts.tests.test_network_process_watch import Queue, registration_event

from Scripts import ws24_emit_installed_qualification_report as ws24
from Scripts.reconstruction import audit_installed_network_acquisition as network
from Scripts.reconstruction import app_preference_recovery as preference_recovery
from Scripts.reconstruction import compile_installed_acceptance_gate_plan as compiler
from Scripts.reconstruction import emit_installed_incremental_xcuitest_evidence as incremental
from Scripts.reconstruction import emit_installed_live_evidence as live_evidence
from Scripts.reconstruction import install_release_to_applications as installer
from Scripts.reconstruction import installed_matrix_receipt as matrix_receipt
from Scripts.reconstruction import run_installed_acceptance_transaction as driver
from Scripts.reconstruction import run_installed_task10_matrix as matrix_runner
from Scripts.reconstruction import run_ws24_installed_live_gates as live_runner
from Scripts.reconstruction import validate_final_local_candidate as final_validator
from Scripts.reconstruction_gate_f.canonical_json import canonical_bytes
from Scripts.tests.installed_acceptance_e2e_fixture import (
    InstalledAcceptanceFixture,
    PREDECESSOR_OBSERVATIONS_SHA256,
    REPOSITORY_ROOT,
    RUN_ID,
    RUN_NONCE,
    read_canonical,
    sha256_file,
    write_canonical,
)

REAL_SUBPROCESS_RUN = subprocess.run


class SyntheticPreferenceStore:
    def __init__(self):
        self.value = b"synthetic provider baseline"

    def read(self):
        return self.value

    def write(self, value):
        self.value = value


def _load_native_runner():
    path = (
        REPOSITORY_ROOT
        / "Scripts/native-decompiler-xpc/run_installed_native_xpc_gate.py"
    )
    name = "installed_acceptance_e2e_native_runner"
    specification = importlib.util.spec_from_file_location(name, path)
    if specification is None or specification.loader is None:
        raise AssertionError("cannot import installed native-XPC runner")
    module = importlib.util.module_from_spec(specification)
    sys.modules[name] = module
    specification.loader.exec_module(module)
    return module


class PhysicalEffectRunner:
    """Execute production orchestration while replacing physical OS effects."""

    def __init__(
        self,
        fixture: InstalledAcceptanceFixture,
        *,
        fail_operation: str | None = None,
        mutate_ws24_envelope: bool = False,
    ) -> None:
        self.fixture = fixture
        self.fail_operation = fail_operation
        self.mutate_ws24_envelope = mutate_ws24_envelope
        self.calls: list[tuple[str, ...]] = []
        self.preference_store = SyntheticPreferenceStore()
        self.native = _load_native_runner()

    @staticmethod
    def _capture(entrypoint, arguments: list[str], **kwargs: object):
        stdout = io.StringIO()
        stderr = io.StringIO()
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            status = entrypoint(arguments, **kwargs)
        return status, stdout.getvalue().encode(), stderr.getvalue().encode()

    def _installer(self, argv: tuple[str, ...]):
        phase = argv[argv.index("--phase") + 1]
        if phase == "begin":
            ticks = iter(
                (self.fixture.begin_time_ns, self.fixture.exposed_time_ns)
            )
            clock = lambda: next(ticks)
        else:
            clock = time.time_ns
        return self._capture(
            installer.main,
            list(argv[3:]),
            _allow_test_destination=True,
            _atomic_rename=self.fixture.atomic_rename,
            _clock_ns=clock,
            _transaction_nonce_factory=lambda: "7" * 64,
        )

    @staticmethod
    def _selectors_document(selectors: list[str]) -> dict[str, object]:
        return {
            "testNodes": [
                {
                    "children": [
                        {
                            "children": [
                                {
                                    "children": [],
                                    "name": identifier.rsplit("/", 1)[-1],
                                    "nodeIdentifier": identifier,
                                    "nodeType": "Test Case",
                                    "result": "Passed",
                                }
                                for identifier in selectors
                            ],
                            "name": "WS24InstalledAppUITests",
                            "nodeType": "Test Suite",
                        }
                    ],
                    "name": "MacScopeInstalledAppUITests",
                    "nodeType": "UI test bundle",
                }
            ]
        }

    def _run_matrix(self, argv: tuple[str, ...], environment: dict[str, str]):
        parsed = matrix_runner.parse_arguments(list(argv[3:]))
        recovery_directory = self.fixture.root / "provider-preference-recovery"
        journal = recovery_directory / "pending.json"
        baseline = self.preference_store.read()

        def protect(app_paths, callback):
            # Keep the exact production journal/restore guard; replace only its
            # native preference store, census, and machine-private destination.
            return preference_recovery.run_with_provider_preference_recovery(
                app_paths, callback, _store=self.preference_store,
                _recovery_directory=recovery_directory,
                _require_quiescent=lambda first, second: None)

        catalog = ws24.load_installed_selector_catalog()
        projection = ws24.installed_selector_projection(catalog)
        selectors = [item["test_identifier"] for item in projection]
        summary = {
            "expectedFailures": 0,
            "failedTests": 0,
            "passedTests": len(selectors),
            "result": "Passed",
            "skippedTests": 0,
            "title": "Test - MacScopeInstalledAppUITests",
            "totalTestCount": len(selectors),
        }

        def execute(_command, _environment, _timeout):
            if not journal.is_file():
                raise AssertionError("synthetic matrix launched without durable preference baseline")
            self.preference_store.value = b"synthetic matrix provider change"
            parsed.xcresult.mkdir(mode=0o700)
            (parsed.xcresult / "Info.plist").write_bytes(b"e2e-xcresult")
            time.sleep(0.003)
            return 0, False

        def export(command, **_kwargs):
            output = Path(command[command.index("--output-path") + 1])
            self.fixture.publish_xcresult_export(output, projection)
            return subprocess.CompletedProcess(command, 0, "", "")

        # The observer session below is simulated; bind its receipt to a
        # physical fixture tool instead of requiring the host macOS binary.
        observer_tool = self.fixture.root / "fixture-nettop"
        observer_tool.write_bytes(b"#!/bin/sh\nexit 0\n")
        observer_tool.chmod(0o700)
        original_audit = network.audit_matrix_workload

        def audit(**kwargs):
            now = time.time_ns() // 1_000_000
            process_ids: dict[str, int] = {}

            def processes(executable_path: str):
                pid = process_ids.setdefault(
                    executable_path,
                    4300 + len(process_ids),
                )
                return (
                    network.ProcessIdentity(
                        pid=pid,
                        executable_path=executable_path,
                        start_time_unix_us=1_000_000 + pid,
                    ),
                )

            def session():
                observer_spawn_ns = time.monotonic_ns()
                return network.ContinuousMatrixObserverSession(
                    argv=network.matrix_observer_argv(),
                    started_at_unix_ms=now,
                    ready_at_unix_ms=now,
                    readiness_frame_sha256=network.hashlib.sha256(
                        network.MATRIX_OBSERVER_READY_FRAME
                    ).hexdigest(),
                    finish=lambda: network.ObserverExecution(
                        returncode=-15,
                        stdout=network.MATRIX_OBSERVER_READY_FRAME * 2,
                        stderr=b"",
                        elapsed_ms=5,
                        stopped_by_auditor=True,
                        observer_eof_ns=time.monotonic_ns(),
                    ),
                    observer_spawn_ns=observer_spawn_ns,
                )

            result = original_audit(
                **kwargs,
                process_provider=processes,
                observer_session_factory=session,
                observer_tool_path=observer_tool,
                watch_collector_factory=lambda paths: ProcessWatchCollector(
                    paths, queue_factory=Queue, event_factory=registration_event
                ),
                pid_census=lambda: (),
            )
            return result

        with (
            mock.patch.dict(os.environ, environment, clear=True),
            mock.patch.object(matrix_runner, "run_with_provider_preference_recovery",
                              side_effect=protect),
            mock.patch.object(
                matrix_runner,
                "_run_xcodebuild_process_group",
                side_effect=execute,
            ),
            mock.patch.object(
                matrix_runner,
                "xcresult_test_summary",
                return_value=summary,
            ),
            mock.patch.object(
                matrix_runner,
                "xcresult_test_nodes",
                return_value=self._selectors_document(selectors),
            ),
            mock.patch.object(
                matrix_runner,
                "audit_matrix_workload",
                side_effect=audit,
            ),
            mock.patch.object(
                matrix_receipt.subprocess,
                "run",
                side_effect=export,
            ),
        ):
            result = self._capture(matrix_runner.main, list(argv[3:]))
        if self.preference_store.read() != baseline or journal.exists():
            raise AssertionError("synthetic matrix did not restore and retire its preference baseline")
        return result

    def _run_native(self, argv: tuple[str, ...]):
        arguments = self.native.parse_arguments(list(argv[1:]))
        application = self.fixture.installed_app / "Contents/MacOS/MacScope"
        service = (
            self.fixture.installed_app
            / "Contents/XPCServices/NativeDecompilerXPCService.xpc/Contents/MacOS/"
            "NativeDecompilerXPCService"
        )
        app_identity = self.native.ProcessIdentity(
            4101, 100, 1, os.geteuid(), str(application)
        )
        service_identity = self.native.ProcessIdentity(
            4102, 100, 2, os.geteuid(), str(service)
        )
        native_probe = self.native.ProductProbe(
            app_identity, service_identity, "Ready: native e2e"
        )
        fallback_probe = self.native.ProductProbe(
            app_identity, None, "MacScope fallback: disabled e2e"
        )
        with (
            mock.patch.object(self.native, "matching_processes", return_value=()),
            mock.patch.object(self.native, "_native_probe", return_value=native_probe),
            mock.patch.object(
                self.native, "_fallback_probe", return_value=fallback_probe
            ),
            mock.patch.object(self.native, "_terminate_owned"),
            mock.patch.object(self.native, "_wait_process_exit", return_value=True),
            mock.patch.object(self.native, "_same_live_process", return_value=False),
        ):
            stdout = io.StringIO()
            stderr = io.StringIO()
            with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
                try:
                    native_result, fallback_result, report = self.native.run_gate(
                        arguments
                    )
                    assert native_result.service is not None
                    assert fallback_result.service is None
                    assert report == arguments.artifact_root / self.native.REPORT_NAME
                    status = 0
                except Exception as error:  # pragma: no cover - surfaced by assertion
                    print(error, file=sys.stderr)
                    status = 1
            return status, stdout.getvalue().encode(), stderr.getvalue().encode()

    def _shell_report(self, mode: str) -> dict[str, object]:
        backend, fallback = {
            ws24.FULL_SURFACE_MODE: (ws24.FULL_SURFACE_BACKEND, None),
            ws24.LEGACY_GRID_MODE: (
                ws24.LEGACY_GRID_BACKEND,
                ws24.LEGACY_GRID_REASON,
            ),
        }[mode]
        suffix = "1" if mode == ws24.FULL_SURFACE_MODE else "2"
        executable = self.fixture.installed_app / "Contents/MacOS/MacScope"
        return {
            "acceptedTranscriptEventCount": 3,
            "appExecutablePath": str(executable),
            "appExecutableSHA256": sha256_file(executable),
            "buildProvenanceSHA256": sha256_file(
                self.fixture.installed_app
                / "Contents/Resources/MacScopeBuildProvenance.json"
            ),
            "cleanupObservedProcessAbsent": True,
            "generatedAtUnixMilliseconds": time.time_ns() // 1_000_000,
            "launchedProcessIdentifier": 4200,
            "observedReply": "reply:installed-e2e",
            "reconnectAcceptedTranscriptEventCount": 1,
            "rendererEvidence": {
                "fallbackReason": fallback,
                "rendererPresented": True,
                "requestedMode": mode,
                "selectedBackend": backend,
                "shellProcessIdentifier": 4200,
                "shellRequestID": f"10000000-0000-0000-0000-00000000001{suffix}",
                "shellSessionID": f"10000000-0000-0000-0000-00000000002{suffix}",
                "transcriptOnlyFallbackPresented": False,
            },
            "schemaVersion": ws24.INSTALLED_SHELL_REPORT_SCHEMA_VERSION,
            "shellBrokerServiceIdentifier": ws24.SHELL_BROKER_SERVICE_IDENTIFIER,
            "shellBrokerWireProtocol": ws24.SHELL_BROKER_WIRE_PROTOCOL,
            "sourceCommit": self.fixture.source_commit,
            "sourceTree": self.fixture.source_tree,
            "status": "passed",
            "supportedCommands": sorted(ws24.REQUIRED_SHELL_COMMANDS),
        }

    def _renderer(self, argv: tuple[str, ...]):
        full = Path(argv[argv.index("--output") + 1])
        legacy = full.with_name("full-surface.legacy-grid.json")
        write_canonical(full, self._shell_report(ws24.FULL_SURFACE_MODE))
        write_canonical(legacy, self._shell_report(ws24.LEGACY_GRID_MODE))
        return 0, b"PASS: installed renderer dual-mode fixture\n", b""

    def _operability_authority(self):
        evidence_root = (
            self.fixture.work_root / driver.GATE_EVIDENCE_ROOT_NAME
        )
        return ws24.validate_operability_authority(
            installed_app=self.fixture.installed_app,
            source_app=self.fixture.source_app,
            candidate_identity=self.fixture.candidate_path,
            expected_source_commit=self.fixture.source_commit,
            qualification_run_id=RUN_ID,
            qualification_run_nonce=RUN_NONCE,
            installation_pending_state=self.fixture.pending_state,
            full_surface_report=evidence_root / "full-surface.json",
            legacy_grid_report=evidence_root / "full-surface.legacy-grid.json",
            native_xpc_execution_report=(
                evidence_root
                / "native-xpc-artifacts"
                / ws24.NATIVE_XPC_EXECUTION_REPORT_NAME
            ),
        )[0]

    def _cli_gui(self, argv: tuple[str, ...]):
        output = Path(argv[argv.index("--output") + 1])
        write_canonical(
            output,
            ws24.operability_report_document(
                report_kind=ws24.CLI_GUI_OPERABILITY_REPORT_KIND,
                probe_results={"cli": True, "gui": True},
                authority=self._operability_authority(),
            ),
        )
        return (
            0,
            (
                "PASS: installed CLI/GUI operability report sha256="
                f"{sha256_file(output)}\n"
            ).encode(),
            b"",
        )

    def _mcp(self, argv: tuple[str, ...]):
        output = Path(argv[argv.index("--output") + 1])
        write_canonical(
            output,
            ws24.operability_report_document(
                report_kind=ws24.MCP_OPERABILITY_REPORT_KIND,
                probe_results={
                    "initialize": True,
                    "readOnlyInfo": True,
                    "toolsList": True,
                },
                authority=self._operability_authority(),
            ),
        )
        return 0, b"PASS: installed MCP operability fixture\n", b""

    @staticmethod
    def _live_payload(spec, authority, *, deadline: float) -> bytes:
        del deadline
        now = max(
            time.time_ns() // 1_000_000,
            (authority.exposed_at_unix_ns + 999_999) // 1_000_000,
        )

        def attempt(index: int, scenario: str, seed, peak):
            return {
                "attemptIndex": index,
                "endedAtUnixMilliseconds": now + 1,
                "exitCode": 0,
                "failure": None,
                "peakResidentMemoryMegabytes": peak,
                "scenario": scenario,
                "seed": seed,
                "startedAtUnixMilliseconds": now,
                "timedOut": False,
            }

        if spec.gate in {
            "installed-launch-smoke",
            "direct-debugger-transport-contracts",
        }:
            attempts = [attempt(1, spec.gate, None, None)]
        elif spec.gate in live_runner.STRESS_GATES:
            attempts = [
                attempt(
                    index,
                    spec.gate,
                    live_runner.deterministic_seed(
                        authority,
                        report_gate=spec.gate,
                        scenario=spec.gate,
                        attempt_index=index,
                    ),
                    None,
                )
                for index in range(1, 11)
            ]
        else:
            attempts = []
            for scenario in (
                "repeated-launch-detach-stress",
                "repeated-attach-detach-stress",
                "repeated-restart-stress",
            ):
                attempts.extend(
                    attempt(
                        index,
                        scenario,
                        live_runner.deterministic_seed(
                            authority,
                            report_gate=spec.gate,
                            scenario=scenario,
                            attempt_index=index,
                        ),
                        128,
                    )
                    for index in range(1, 11)
                )
        payload = canonical_bytes(
            {
                "attempts": attempts,
                "gate": spec.gate,
                "installedExecutableSHA256": (
                    authority.installed_executable_sha256
                ),
                "schemaVersion": live_runner.LIVE_REPORT_SCHEMA_VERSION,
                "sourceCommit": authority.source_commit,
                "sourceTree": authority.source_tree,
            }
        )
        return live_runner.validate_report_payload(payload, spec, authority)

    def _xcresulttool(self, command, **_kwargs):
        if (
            len(command) >= 2
            and Path(command[1]).name == "check_local_signing_policy.py"
        ):
            return subprocess.CompletedProcess(
                command,
                0,
                "PASS: physical local-signing fixture\n",
                "",
            )
        projection = ws24.installed_selector_projection(
            ws24.load_installed_selector_catalog()
        )
        selectors = [item["test_identifier"] for item in projection]
        if command[:4] != [
            "/usr/bin/xcrun",
            "xcresulttool",
            "get",
            "test-results",
        ]:
            return REAL_SUBPROCESS_RUN(command, **_kwargs)
        if command[4] == "summary":
            document = {
                "expectedFailures": 0,
                "failedTests": 0,
                "passedTests": len(selectors),
                "result": "Passed",
                "skippedTests": 0,
                "title": "Test - MacScopeInstalledAppUITests",
                "totalTestCount": len(selectors),
            }
        elif command[4] == "tests":
            document = self._selectors_document(selectors)
        else:
            raise AssertionError(f"unexpected xcresulttool report: {command[4]!r}")
        return subprocess.CompletedProcess(
            command,
            0,
            json.dumps(document, sort_keys=True),
            "",
        )

    def _live_manifest(self, argv: tuple[str, ...]):

        with (
            mock.patch.object(
                live_evidence,
                "CANONICAL_INSTALLED_APP",
                self.fixture.installed_app,
            ),
            mock.patch.object(live_runner, "INSTALLED_APP", self.fixture.installed_app),
            mock.patch.object(
                live_runner,
                "INSTALLED_EXECUTABLE",
                self.fixture.installed_app / "Contents/MacOS/MacScope",
            ),
            mock.patch.object(
                live_runner,
                "PROVENANCE",
                self.fixture.installed_app
                / "Contents/Resources/MacScopeBuildProvenance.json",
            ),
            mock.patch.object(
                live_runner,
                "run_installed_gate",
                side_effect=self._live_payload,
            ),
            mock.patch.object(
                ws24.subprocess,
                "run",
                side_effect=self._xcresulttool,
            ),
        ):
            return self._capture(live_evidence.main, list(argv[3:]))

    def _ws24(self, argv: tuple[str, ...]):
        with (
            mock.patch.object(ws24.subprocess, "run", side_effect=self._xcresulttool),
            mock.patch.object(ws24.platform, "machine", return_value="arm64"),
            mock.patch.object(
                ws24.platform, "mac_ver",
                return_value=("27.0", ("", "", ""), ""),
            ),
        ):
            result = self._capture(ws24.main, list(argv[3:]))
        if result[0] == 0 and self.mutate_ws24_envelope:
            envelope = (
                self.fixture.work_root
                / driver.QUALIFICATION_ROOT_NAME
                / "mcp.acceptance-gate.json"
            )
            document = read_canonical(envelope)
            document["gate_id"] = "cli"
            write_canonical(envelope, document)
        return result

    def __call__(self, argv, _timeout, environment):
        argv = tuple(argv)
        self.calls.append(argv)
        if "--phase" in argv:
            stage = argv[argv.index("--phase") + 1]
        elif len(argv) >= 3 and Path(argv[2]) == Path(compiler.__file__).resolve():
            stage = "compiler"
        elif len(argv) >= 3 and Path(argv[2]) == Path(matrix_runner.__file__).resolve():
            stage = "task10"
        elif len(argv) >= 3 and Path(argv[2]) == Path(incremental.__file__).resolve():
            stage = "incremental"
        elif argv[0].endswith("run_installed_native_xpc_gate.py"):
            stage = "native-xpc-probe"
        elif len(argv) >= 3 and argv[2].endswith("run_installed_shell_smoke.py"):
            stage = "renderer-dual"
        elif argv[0] == "/bin/bash" and argv[1].endswith("cli_gui_operability_smoke.sh"):
            stage = "cli-gui-operability"
        elif argv[0] == "/bin/bash" and argv[1].endswith("mcp_operability_smoke.sh"):
            stage = "mcp-probe"
        elif len(argv) >= 3 and argv[2].endswith("emit_installed_live_evidence.py"):
            stage = "shellbroker-launchagent-probe"
        elif len(argv) >= 3 and argv[2].endswith("ws24_emit_installed_qualification_report.py"):
            stage = "ws24-finalize"
        else:
            raise AssertionError(f"unexpected production command: {argv!r}")

        if stage == self.fail_operation:
            return driver.CommandResult(argv, 70, b"", b"physical fixture failure\n")
        if stage in {"begin", "commit", "rollback"}:
            status, stdout, stderr = self._installer(argv)
        elif stage == "compiler":
            status, stdout, stderr = self._capture(compiler.main, list(argv[3:]))
        elif stage == "task10":
            status, stdout, stderr = self._run_matrix(argv, dict(environment))
        elif stage == "incremental":
            status, stdout, stderr = self._capture(incremental.main, list(argv[3:]))
        elif stage == "native-xpc-probe":
            status, stdout, stderr = self._run_native(argv)
        elif stage == "renderer-dual":
            status, stdout, stderr = self._renderer(argv)
        elif stage == "cli-gui-operability":
            status, stdout, stderr = self._cli_gui(argv)
        elif stage == "mcp-probe":
            status, stdout, stderr = self._mcp(argv)
        elif stage == "shellbroker-launchagent-probe":
            status, stdout, stderr = self._live_manifest(argv)
        else:
            status, stdout, stderr = self._ws24(argv)
        return driver.CommandResult(argv, status, stdout, stderr)


class InstalledAcceptanceEndToEndTests(unittest.TestCase):
    def test_installed_acceptance_end_to_end_contract(self) -> None:
        fixture = InstalledAcceptanceFixture()
        interpreters = macos_interpreter_files(fixture.root)
        interpreters.__enter__()
        self.addCleanup(interpreters.__exit__, None, None, None)
        observer_path = mock.patch.object(
            network, "NETTOP_PATH", fixture.root / "fixture-nettop"
        )
        observer_path.start()
        self.addCleanup(observer_path.stop)
        # This fixture exercises physical bundle transactions, not the host's
        # real application census. Production always uses the real guard.
        quiescence = mock.patch.object(driver, "require_app_quiescent", return_value=None)
        quiescence.start()
        self.addCleanup(quiescence.stop)
        compiler_path = Path(compiler.__file__).resolve()
        arguments = fixture.transaction_arguments(compiler_path)
        result_path = fixture.work_root / driver.RESULT_NAME
        final_path = fixture.root / "FINAL_LOCAL_CANDIDATE.json"
        try:
            for failure in (
                PhysicalEffectRunner(fixture, fail_operation="mcp-probe"),
                PhysicalEffectRunner(fixture, mutate_ws24_envelope=True),
            ):
                stdout = io.StringIO()
                stderr = io.StringIO()
                with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
                    status = driver.main(
                        arguments,
                        _allow_test_destination=True,
                        _runner=failure,
                        _install_signal_handlers=False,
                    )
                self.assertEqual(status, 1, stderr.getvalue())
                self.assertIn("rollback=rolled-back", stderr.getvalue())
                self.assertFalse(result_path.exists())
                self.assertFalse(final_path.exists())
                self.assertFalse(fixture.installed_app.exists())
                fixture.reset_after_rollback()

            success = PhysicalEffectRunner(fixture)
            stdout = io.StringIO()
            stderr = io.StringIO()
            with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
                status = driver.main(
                    arguments,
                    _allow_test_destination=True,
                    _runner=success,
                    _install_signal_handlers=False,
                )
            self.assertEqual(status, 0, stderr.getvalue())
            self.assertEqual(stdout.getvalue().encode(), f"{result_path}\n".encode())

            result = read_canonical(result_path)
            self.assertEqual(
                [item["gate_id"] for item in result["gate_envelopes"]],
                list(installer.REQUIRED_ACCEPTANCE_GATES),
            )
            self.assertEqual(result["candidate"]["source_commit"], fixture.source_commit)
            self.assertEqual(result["candidate"]["source_tree"], fixture.source_tree)
            task10 = result["installed_task10"]
            self.assertEqual(
                set(task10),
                {
                    "incremental_evidence",
                    "matrix_receipt",
                    "network_artifact_root",
                    "xcresult",
                    "xcresult_semantic_manifest",
                },
            )
            network_root = (
                fixture.work_root
                / driver.GATE_EVIDENCE_ROOT_NAME
                / "installed-task10-network"
            )
            network_record = task10["network_artifact_root"]
            self.assertEqual(
                set(network_record),
                {
                    "audit_report_path",
                    "audit_report_sha256",
                    "execution_report_path",
                    "execution_report_sha256",
                    "observation_path",
                    "observation_sha256",
                    "path",
                },
            )
            self.assertEqual(network_record["path"], str(network_root))
            self.assertEqual(
                {item.name for item in network_root.iterdir()},
                {
                    driver.NETWORK_AUDIT_REPORT_NAME,
                    driver.NETWORK_EXECUTION_REPORT_NAME,
                    driver.NETWORK_OBSERVATION_NAME,
                    driver.TASK10_INCREMENTAL_EVIDENCE_NAME,
                },
            )
            expected_network_files = {
                "audit_report": network_root / driver.NETWORK_AUDIT_REPORT_NAME,
                "execution_report": (
                    network_root / driver.NETWORK_EXECUTION_REPORT_NAME
                ),
                "observation": network_root / driver.NETWORK_OBSERVATION_NAME,
            }
            for field, path in expected_network_files.items():
                self.assertEqual(network_record[f"{field}_path"], str(path))
                self.assertEqual(
                    network_record[f"{field}_sha256"],
                    sha256_file(path),
                )
                self.assertFalse(path.is_symlink())
                self.assertEqual(path.stat().st_nlink, 1)
            for record in (
                task10["matrix_receipt"],
                task10["xcresult_semantic_manifest"],
                task10["incremental_evidence"],
            ):
                self.assertEqual(set(record), {"path", "sha256"})
                self.assertEqual(sha256_file(Path(record["path"])), record["sha256"])
            self.assertEqual(
                Path(task10["incremental_evidence"]["path"]).parent,
                network_root,
            )
            xcresult_record = task10["xcresult"]
            self.assertEqual(
                set(xcresult_record),
                {"bundle_sha256", "closed_tree_sha256", "path"},
            )
            xcresult_path = Path(xcresult_record["path"])
            self.assertEqual(
                xcresult_path,
                fixture.work_root
                / driver.GATE_EVIDENCE_ROOT_NAME
                / "InstalledTask10.xcresult",
            )
            self.assertFalse(xcresult_path.is_symlink())
            self.assertEqual(
                ws24.result_bundle_sha256(xcresult_path),
                xcresult_record["bundle_sha256"],
            )
            xcresult_digests = matrix_receipt._fenced_tree_digests(
                xcresult_path
            )
            self.assertEqual(
                xcresult_digests.closed_tree_sha256,
                xcresult_record["closed_tree_sha256"],
            )

            local_ref = final_validator._resolve_local_ref(
                fixture.repository_root, fixture.integration_ref
            )
            self.assertEqual(local_ref.commit, fixture.source_commit)
            self.assertEqual(local_ref.tree, fixture.source_tree)

            # A full canonical source export is 1.6+ GiB in this repository.
            # Keep this focused E2E hermetic while retaining real local-ref,
            # candidate, transaction, and final-receipt validation authority.
            qualification_file = final_validator._read_stable_file(
                fixture.qualification_receipt,
                maximum_bytes=final_validator.MAX_QUALIFICATION_RECEIPT_BYTES,
                label="fixture qualification receipt",
            )
            coverage_file = final_validator._read_stable_file(
                fixture.coverage,
                maximum_bytes=final_validator.MAX_COVERAGE_BYTES,
                label="fixture coverage",
            )
            qualification_document = json.loads(
                fixture.qualification_receipt.read_text(encoding="utf-8")
            )
            validated = SimpleNamespace(
                dependency_files=(),
                run_root=fixture.qualification_root,
            )
            qualification = final_validator.QualificationAuthority(
                document=qualification_document,
                receipt=qualification_file,
                validated=validated,
                source_provenance=qualification_document["source_identity"],
                source_provenance_sha256=sha256_file(
                    fixture.qualification_root / "source/SOURCE_PROVENANCE.json"
                ),
                result_bundle=fixture.result_bundle,
                coverage=coverage_file,
            )
            final_arguments = [
                "--transaction-result",
                str(result_path),
                "--integration-ref",
                fixture.integration_ref,
                "--qualification-receipt",
                str(fixture.qualification_receipt),
                "--candidate-artifact-root",
                str(fixture.candidate_root),
                "--output",
                str(final_path),
            ]
            final_stdout = io.StringIO()
            final_stderr = io.StringIO()
            with (
                mock.patch.object(final_validator, "REPOSITORY_ROOT", fixture.repository_root),
                mock.patch.object(
                    final_validator,
                    "_validate_qualification",
                    return_value=qualification,
                ),
                contextlib.redirect_stdout(final_stdout),
                contextlib.redirect_stderr(final_stderr),
            ):
                final_status = final_validator.main(
                    final_arguments,
                    _allow_test_destination=True,
                    _clock_ns=lambda: time.time_ns(),
                )
            self.assertEqual(final_status, 0, final_stderr.getvalue())
            self.assertEqual(final_stdout.getvalue().encode(), f"{final_path}\n".encode())
            final = read_canonical(final_path)
            self.assertEqual(
                final["scope"],
                {
                    "authority": "local-private-candidate-only",
                    "gate_f_claimed": False,
                    "online_delivery_claimed": False,
                    "post_2026_09_11_proof_claimed": False,
                    "public_release_claimed": False,
                },
            )
            self.assertEqual(
                final["transaction_result"]["installed_task10"],
                result["installed_task10"],
            )
        finally:
            fixture.cleanup()


if __name__ == "__main__":
    unittest.main()
