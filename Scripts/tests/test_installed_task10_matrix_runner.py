#!/usr/bin/env python3

from __future__ import annotations

import io
import json
import os
from pathlib import Path
import plistlib
import sys
import tempfile
import time
import unittest
from contextlib import redirect_stderr, redirect_stdout
from unittest import mock

from Scripts.reconstruction import run_installed_task10_matrix as runner
from Scripts.reconstruction import app_preference_recovery as recovery
from Scripts.reconstruction.installed_matrix_receipt import (
    INSTALLED_APP_KEY,
    OPT_IN_KEY,
    expected_argv,
)
from Scripts.ws24_emit_installed_qualification_report import (
    load_installed_selector_catalog,
)


class InstalledTask10MatrixRunnerTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name).resolve()
        self.candidate = self._file("candidate.json")
        self.preparation = self._file("preparation.json")
        self.installed_app = self._directory("Applications/MacScope.app")
        self._file("Applications/MacScope.app/Contents/MacOS/MacScope")
        (self.installed_app / "Contents/Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": "org.macscope.app", "CFBundleExecutable": "MacScope"}))
        class SyntheticPreferenceStore:
            value = b"synthetic baseline"
            fail_write = False
            def read(store):
                return store.value
            def write(store, value):
                if store.fail_write:
                    raise RuntimeError("synthetic restoration failure")
                store.value = value
        self.preference_store = SyntheticPreferenceStore()
        def protect(app_paths, callback):
            return recovery.run_with_provider_preference_recovery(
                app_paths, callback, _store=self.preference_store,
                _recovery_directory=self.root / "private-recovery",
                _require_quiescent=lambda first, second: None)
        self.protection = mock.patch.object(runner, "run_with_provider_preference_recovery",
                                            side_effect=protect, create=True)
        self.protection.start()
        self.addCleanup(self.protection.stop)
        self.xctestrun = self._file("Products/Installed.xctestrun")
        with self.xctestrun.open("wb") as stream:
            plistlib.dump(
                {
                    "__xctestrun_metadata__": {
                        "ContainerInfo": {"SchemeName": "MacScopeInstalledAppUITests"}
                    },
                    "MacScopeInstalledAppUITests": {
                        "BlueprintName": "MacScopeInstalledAppUITests",
                        "EnvironmentVariables": {"TERM": "dumb"},
                        "TestingEnvironmentVariables": {
                            "XCODE_SCHEME_NAME": "MacScopeInstalledAppUITests"
                        },
                    },
                },
                stream,
            )
        self.ui_runner = self._directory(
            "Products/Debug/MacScopeInstalledAppUITests-Runner.app"
        )
        self.test_bundle = self._directory(
            "Products/Debug/MacScopeInstalledAppUITests-Runner.app/Contents/PlugIns/"
            "MacScopeInstalledAppUITests.xctest"
        )
        self.xcresult = self.root / "Results/Installed.xcresult"
        self.xcresult.parent.mkdir()
        self.xcresult_semantic_manifest = Path(f"{self.xcresult}.semantic.json")
        self.receipt = self.root / "Results/installed-matrix.json"
        self.network_artifact_root = self.root / "Results/installed-network"
        self.qualification_run_id = "task11-local-premerge-run"
        self.qualification_run_nonce = "a" * 64
        self.predecessor_observations_sha256 = "b" * 64
        self.developer_dir = self._directory("Xcode.app/Contents/Developer")
        self.xcodebuild = self._file(
            "Xcode.app/Contents/Developer/usr/bin/xcodebuild"
        )
        self.xcodebuild.chmod(0o755)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def _file(self, relative: str) -> Path:
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(b"fixture")
        return path

    def _directory(self, relative: str) -> Path:
        path = self.root / relative
        path.mkdir(parents=True, exist_ok=True)
        return path

    def arguments(self) -> list[str]:
        return [
            "--candidate-identity",
            str(self.candidate),
            "--preparation-receipt",
            str(self.preparation),
            "--installed-app",
            str(self.installed_app),
            "--xctestrun",
            str(self.xctestrun),
            "--test-bundle",
            str(self.test_bundle),
            "--ui-runner",
            str(self.ui_runner),
            "--xcresult",
            str(self.xcresult),
            "--xcresult-semantic-manifest",
            str(self.xcresult_semantic_manifest),
            "--receipt-output",
            str(self.receipt),
            "--network-artifact-root",
            str(self.network_artifact_root),
            "--qualification-run-id",
            self.qualification_run_id,
            "--qualification-run-nonce",
            self.qualification_run_nonce,
            "--predecessor-observations-sha256",
            self.predecessor_observations_sha256,
            "--developer-dir",
            str(self.developer_dir),
        ]

    def test_runner_uses_the_single_catalog_and_closed_opt_in_environment(self) -> None:
        captured: dict[str, object] = {}
        prepared_bytes = self.xctestrun.read_bytes()

        def execute(
            command: list[str], environment: dict[str, str], timeout_seconds: int
        ) -> tuple[int, bool]:
            self.preference_store.value = None
            captured["command"] = command
            captured["environment"] = environment
            captured["timeout_seconds"] = timeout_seconds
            self.xcresult.mkdir()
            (self.xcresult / "Info.plist").write_bytes(b"result")
            return 0, False

        def create_document(**kwargs: object) -> dict[str, object]:
            self.assertEqual(self.preference_store.value, b"synthetic baseline",
                             "matrix evidence admitted before preference restoration")
            captured["document"] = kwargs
            projection = kwargs["selector_projection"]
            return {
                "candidate": {"identity_sha256": "d" * 64},
                "execution": {"result": "passed"},
                "products": {"xcresult": {"closed_tree_sha256": "c" * 64}},
                "accessibility_observations": {
                    "observed_selector_projection": [
                        {
                            "observed_identifiers": sorted(item["required_identifiers"]),
                            "test_identifier": item["test_identifier"],
                            "vector_id": item["vector_id"],
                        }
                        for item in projection
                    ]
                },
            }

        def audit_matrix_workload(**kwargs: object):
            captured["audit"] = kwargs
            value, evidence = kwargs["workload"]()
            projection = [
                {
                    "vector_id": item["vectorID"],
                    "test_identifier": item["testIdentifier"],
                    "required_identifiers": item["requiredIdentifiers"],
                }
                for item in load_installed_selector_catalog()
            ]
            if evidence.get("selector_projection_sha256") != runner.canonical_sha256(projection):
                raise AssertionError("matrix producer omitted or altered selector projection")
            captured["workload_evidence"] = evidence
            return value, {"result": "passed"}, 0

        stdout = io.StringIO()
        stderr = io.StringIO()
        with (
            mock.patch.object(runner, "preflight_execution", return_value={"fixture": "stable"}),
            mock.patch.object(runner, "capture_input_snapshot", return_value={"fixture": "stable"}),
            mock.patch.object(runner, "assert_input_snapshot_equal"),
            mock.patch.object(
                runner,
                "audit_matrix_workload",
                side_effect=audit_matrix_workload,
            ),
            mock.patch.object(
                runner, "_run_xcodebuild_process_group", side_effect=execute
            ),
            mock.patch.object(runner, "create_document", side_effect=create_document),
            mock.patch.object(
                runner,
                "write_create_only",
                side_effect=lambda _path, document: runner.canonical_sha256(document),
            ),
            mock.patch.object(
                runner,
                "_validate_exact_xcresult",
                return_value={
                    "expected_selector_count": 22,
                    "executed_selector_count": 22,
                    "passed_selector_count": 22,
                    "failed_selector_count": 0,
                    "skipped_selector_count": 0,
                    "selectors": [
                        {
                            "test_identifier": item["testIdentifier"],
                            "status": "passed",
                        }
                        for item in load_installed_selector_catalog()
                    ],
                },
            ),
            mock.patch.object(runner, "result_bundle_sha256", return_value="b" * 64),
            mock.patch.object(runner.time, "time", side_effect=[1.0, 1.5]),
            redirect_stdout(stdout),
            redirect_stderr(stderr),
        ):
            returncode = runner.main(self.arguments())

        self.assertEqual(returncode, 0, stderr.getvalue())
        selectors = [
            item["testIdentifier"] for item in load_installed_selector_catalog()
        ]
        selector_projection = [
            {
                "vector_id": item["vectorID"],
                "test_identifier": item["testIdentifier"],
                "required_identifiers": item["requiredIdentifiers"],
            }
            for item in load_installed_selector_catalog()
        ]
        observed_selector_projection = [
            {
                "observed_identifiers": sorted(item["required_identifiers"]),
                "test_identifier": item["test_identifier"],
                "vector_id": item["vector_id"],
            }
            for item in selector_projection
        ]
        execution_xctestrun = Path(captured["command"][3])
        self.assertNotEqual(execution_xctestrun, self.xctestrun)
        self.assertEqual(execution_xctestrun.parent, self.xctestrun.parent)
        self.assertEqual(
            captured["command"],
            expected_argv(self.xcodebuild, execution_xctestrun, self.xcresult, selectors),
        )
        self.assertEqual(self.xctestrun.read_bytes(), prepared_bytes)
        with execution_xctestrun.open("rb") as stream:
            execution_document = plistlib.load(stream)
        suite = execution_document["MacScopeInstalledAppUITests"]
        for field in ("EnvironmentVariables", "TestingEnvironmentVariables"):
            self.assertEqual(suite[field][OPT_IN_KEY], "1")
            self.assertEqual(suite[field][INSTALLED_APP_KEY], str(self.installed_app))
        self.assertEqual(suite["EnvironmentVariables"]["TERM"], "dumb")
        self.assertEqual(
            suite["TestingEnvironmentVariables"]["XCODE_SCHEME_NAME"],
            "MacScopeInstalledAppUITests",
        )
        self.assertEqual(captured["document"]["prepared_xctestrun"], self.xctestrun)
        self.assertEqual(
            captured["document"]["execution_xctestrun"], execution_xctestrun
        )
        recorded = captured["document"]["environment"]
        process_environment = captured["environment"]
        self.assertEqual(recorded, process_environment)
        self.assertEqual(process_environment[OPT_IN_KEY], "1")
        self.assertEqual(process_environment[INSTALLED_APP_KEY], str(self.installed_app))
        self.assertEqual(captured["document"]["selectors"], selectors)
        self.assertEqual(len(selectors), 22)
        self.assertEqual(json.loads(stdout.getvalue())["selectorCount"], 22)
        self.assertEqual(captured["audit"]["candidate_identity_path"], self.candidate)
        self.assertEqual(captured["audit"]["app_bundle"], self.installed_app)
        self.assertEqual(
            captured["audit"]["artifact_root"], self.network_artifact_root
        )
        self.assertEqual(
            captured["audit"]["qualification_run"].run_id,
            self.qualification_run_id,
        )
        self.assertEqual(
            captured["audit"]["qualification_run"].nonce,
            self.qualification_run_nonce,
        )
        self.assertEqual(
            captured["audit"]["predecessor_observations_sha256"],
            self.predecessor_observations_sha256,
        )

        self.assertEqual(json.loads(stdout.getvalue())["networkAuditResult"], "passed")
        self.assertEqual(captured["workload_evidence"]["matrix_result"], "passed")
        self.assertEqual(captured["workload_evidence"]["executed_selector_count"], 22)
        self.assertEqual(
            captured["workload_evidence"]["selector_projection_sha256"],
            runner.canonical_sha256(selector_projection),
        )
        self.assertEqual(
            json.loads(stdout.getvalue())["xcresultSemanticManifestPath"],
            str(self.xcresult_semantic_manifest),
        )
        self.assertEqual(
            captured["workload_evidence"]["xcresult_semantic_manifest_sha256"],
            runner.canonical_sha256(
                {
                    "schema_version": 3,
                    "candidate_identity_sha256": "d" * 64,
                    "source_xcresult": {
                        "bundle_sha256": "b" * 64,
                        "closed_tree_sha256": "c" * 64,
                    },
                    "selector_catalog_sha256": runner.canonical_sha256(selectors),
                    "selector_projection": selector_projection,
                    "selector_projection_sha256": runner.canonical_sha256(
                        selector_projection
                    ),
                    "observed_selector_projection": observed_selector_projection,
                    "observed_selector_projection_sha256": runner.canonical_sha256(
                        observed_selector_projection
                    ),
                    "expected_selector_count": 22,
                    "executed_selector_count": 22,
                    "passed_selector_count": 22,
                    "failed_selector_count": 0,
                    "skipped_selector_count": 0,
                    "selectors": [
                        {"test_identifier": identifier, "status": "passed"}
                        for identifier in selectors
                    ],
                    "result": "passed",
                }
            ),
        )

    def test_restore_failure_refuses_matrix_admission_and_favorable_publication(self):
        def execute(*unused):
            self.preference_store.value = None
            self.preference_store.fail_write = True
            return 0, False
        def audit(**kwargs):
            value, evidence = kwargs["workload"]()
            return value, {"result": "passed"}, 0
        stdout, stderr = io.StringIO(), io.StringIO()
        with (
            mock.patch.object(runner, "preflight_execution", return_value={}),
            mock.patch.object(runner, "audit_matrix_workload", side_effect=audit),
            mock.patch.object(runner, "_run_xcodebuild_process_group", side_effect=execute),
            mock.patch.object(runner, "capture_input_snapshot") as admission,
            mock.patch.object(runner, "create_document") as document,
            mock.patch.object(runner, "write_create_only") as publication,
            redirect_stdout(stdout), redirect_stderr(stderr),
        ):
            self.assertEqual(runner.main(self.arguments()), 2)
        admission.assert_not_called()
        document.assert_not_called()
        publication.assert_not_called()
        self.assertEqual(stdout.getvalue(), "")
        self.assertTrue((self.root / "private-recovery/pending.json").exists())

    def test_child_error_reports_separate_restoration_failure(self):
        def execute(*unused):
            self.preference_store.fail_write = True
            raise runner.InstalledMatrixReceiptError("synthetic original child failure")
        def audit(**kwargs):
            return kwargs["workload"]()
        stdout, stderr = io.StringIO(), io.StringIO()
        with (
            mock.patch.object(runner, "preflight_execution", return_value={}),
            mock.patch.object(runner, "audit_matrix_workload", side_effect=audit),
            mock.patch.object(runner, "_run_xcodebuild_process_group", side_effect=execute),
            redirect_stdout(stdout), redirect_stderr(stderr),
        ):
            self.assertEqual(runner.main(self.arguments()), 2)
        self.assertIn("synthetic original child failure", stderr.getvalue())
        self.assertIn("provider preference restoration failed", stderr.getvalue())
        self.assertEqual(stdout.getvalue(), "")

    def test_abnormal_wait_retains_baseline_without_claiming_settlement(self):
        original = KeyboardInterrupt()
        process = mock.Mock(pid=12345)
        def fail_wait(**kwargs):
            self.preference_store.value = None
            raise original
        process.wait.side_effect = fail_wait
        with (
            mock.patch.object(runner.subprocess, "Popen", return_value=process),
            mock.patch.object(runner.os, "getpgid", return_value=process.pid),
            mock.patch.object(runner, "_terminate_timed_out_process_group") as cleanup,
        ):
            with self.assertRaises(KeyboardInterrupt) as caught:
                recovery.run_with_provider_preference_recovery(
                    (self.installed_app,), lambda: runner._run_xcodebuild_process_group([], {}, 1),
                    _store=self.preference_store, _recovery_directory=self.root / "private-recovery",
                    _require_quiescent=lambda first, second: None)
        self.assertIs(caught.exception, original)
        cleanup.assert_not_called()
        self.assertIs(original._macscope_preference_writer_unsettled, True)
        self.assertIsNone(self.preference_store.value)
        self.assertTrue((self.root / "private-recovery/pending.json").exists())

    def test_abnormal_wait_error_retains_journal_and_reports_unsettled_writer(self):
        original = runner.InstalledMatrixReceiptError("synthetic original wait failure")
        process = mock.Mock(pid=12345)
        diagnostics = io.StringIO()
        journal_bytes = []
        def fail_wait(**kwargs):
            journal_bytes.append((self.root / "private-recovery/pending.json").read_bytes())
            self.preference_store.value = None
            raise original
        process.wait.side_effect = fail_wait
        with (
            mock.patch.object(runner.subprocess, "Popen", return_value=process),
            mock.patch.object(runner.os, "getpgid", return_value=process.pid),
            mock.patch.object(runner.os, "killpg") as signal_group,
            redirect_stderr(diagnostics),
        ):
            with self.assertRaises(runner.InstalledMatrixReceiptError) as caught:
                recovery.run_with_provider_preference_recovery(
                    (self.installed_app,), lambda: runner._run_xcodebuild_process_group([], {}, 1),
                    _store=self.preference_store, _recovery_directory=self.root / "private-recovery",
                    _require_quiescent=lambda first, second: None)
        self.assertIs(caught.exception, original)
        signal_group.assert_not_called()
        self.assertIs(original._macscope_preference_writer_unsettled, True)
        self.assertIsNone(self.preference_store.value)
        self.assertEqual((self.root / "private-recovery/pending.json").read_bytes(), journal_bytes[0])
        expected = "provider preference writer settlement unproven; private journal retained for explicit recovery"
        if hasattr(original, "add_note"):
            self.assertEqual(original.__notes__, [expected])
            self.assertEqual(diagnostics.getvalue(), "")
        else:
            self.assertEqual(diagnostics.getvalue(), expected + "\n")

    def check_abnormal_wait_ownership(self, process, expected_signals, *, timeout=False):
        original = runner.subprocess.TimeoutExpired("synthetic child", 1) if timeout else KeyboardInterrupt()
        journal = self.root / "private-recovery/pending.json"
        journal_bytes = []
        def fail_wait(**kwargs):
            journal_bytes.append(journal.read_bytes())
            self.preference_store.value = None
            raise original
        process.wait.side_effect = fail_wait
        diagnostics = io.StringIO()
        with (
            mock.patch.object(runner.subprocess, "Popen", return_value=process),
            mock.patch.object(runner.os, "getpgid", return_value=process.pid),
            mock.patch.object(runner.os, "killpg") as signal_group,
            mock.patch.object(runner, "_process_group_exists", return_value=True),
            redirect_stderr(diagnostics),
        ):
            with self.assertRaises(BaseException) as caught:
                recovery.run_with_provider_preference_recovery(
                    (self.installed_app,), lambda: runner._run_xcodebuild_process_group(
                        [], {}, 1, term_grace_seconds=0, kill_grace_seconds=0),
                    _store=self.preference_store, _recovery_directory=journal.parent,
                    _require_quiescent=lambda first, second: None)
        if timeout:
            self.assertIsInstance(caught.exception, runner.InstalledMatrixReceiptError)
        else:
            self.assertIs(caught.exception, original)
        self.assertIs(caught.exception._macscope_preference_writer_unsettled, True)
        self.assertEqual(journal.read_bytes(), journal_bytes[0])
        self.assertIsNone(self.preference_store.value)
        self.assertEqual(signal_group.call_args_list, [
            mock.call(process.pid, process_signal) for process_signal in expected_signals])

    def test_reaped_leader_before_abnormal_wait_cannot_signal_numeric_group(self):
        process = mock.Mock(pid=12345, returncode=0)
        process.poll.return_value = 0
        self.check_abnormal_wait_ownership(process, [])

    def test_ownership_poll_reaping_leader_cannot_signal_numeric_group(self):
        process = mock.Mock(pid=12345, returncode=None)
        def reap():
            process.returncode = 0
            return 0
        process.poll.side_effect = reap
        self.check_abnormal_wait_ownership(process, [], timeout=True)

    def test_leader_reaped_during_term_grace_prevents_unproven_kill(self):
        process = mock.Mock(pid=12345, returncode=None)
        process.poll.side_effect = [None, 0, 0]
        self.check_abnormal_wait_ownership(process, [runner.signal.SIGTERM], timeout=True)

    def test_unknown_abnormal_wait_outcome_retains_journal_without_signalling(self):
        process = mock.Mock(pid=12345, returncode=None)
        process.poll.return_value = None
        self.check_abnormal_wait_ownership(process, [])

    def test_unreaped_owned_timeout_can_escalate_and_restore_after_settlement(self):
        process = mock.Mock(pid=12345, returncode=None)
        process.poll.return_value = None
        def timeout(**kwargs):
            self.preference_store.value = None
            raise runner.subprocess.TimeoutExpired("synthetic child", 1)
        process.wait.side_effect = timeout
        with (
            mock.patch.object(runner.subprocess, "Popen", return_value=process),
            mock.patch.object(runner.os, "getpgid", return_value=process.pid),
            mock.patch.object(runner.os, "killpg") as signal_group,
            mock.patch.object(runner, "_process_group_exists", side_effect=[True, False]),
        ):
            result = recovery.run_with_provider_preference_recovery(
                (self.installed_app,), lambda: runner._run_xcodebuild_process_group(
                    [], {}, 1, term_grace_seconds=0, kill_grace_seconds=0),
                _store=self.preference_store, _recovery_directory=self.root / "private-recovery",
                _require_quiescent=lambda first, second: None)
        self.assertEqual(result, (124, True))
        self.assertEqual(signal_group.call_args_list, [
            mock.call(process.pid, runner.signal.SIGTERM),
            mock.call(process.pid, runner.signal.SIGKILL)])
        self.assertEqual(self.preference_store.value, b"synthetic baseline")
        self.assertFalse((self.root / "private-recovery/pending.json").exists())

    def test_successful_wait_with_live_descendants_cannot_restore_or_return_success(self):
        process = mock.Mock(pid=12345)
        def successful_wait(**kwargs):
            self.preference_store.value = None
            return 0
        process.wait.side_effect = successful_wait
        with (
            mock.patch.object(runner.subprocess, "Popen", return_value=process),
            mock.patch.object(runner.os, "getpgid", return_value=process.pid),
            mock.patch.object(runner, "_wait_for_process_group_exit", return_value=False),
        ):
            with self.assertRaises(runner.InstalledMatrixReceiptError):
                recovery.run_with_provider_preference_recovery(
                    (self.installed_app,), lambda: runner._run_xcodebuild_process_group([], {}, 1),
                    _store=self.preference_store, _recovery_directory=self.root / "private-recovery",
                    _require_quiescent=lambda first, second: None)
        self.assertIsNone(self.preference_store.value)
        self.assertTrue((self.root / "private-recovery/pending.json").exists())

    def test_early_process_identity_failures_retain_journal_without_restoration(self):
        for kind in ("missing leader census", "unexpected group kill"):
            with self.subTest(boundary=kind):
                original = OSError("synthetic early boundary failure")
                process = mock.Mock(pid=12345)
                process.kill.side_effect = original
                def spawn(*args, **kwargs):
                    self.preference_store.value = None
                    return process
                directory = self.root / kind.replace(" ", "-")
                with (
                    mock.patch.object(runner.subprocess, "Popen", side_effect=spawn),
                    mock.patch.object(runner.os, "getpgid", side_effect=(
                        ProcessLookupError() if kind == "missing leader census" else None),
                        return_value=12346),
                    mock.patch.object(runner, "_wait_for_process_group_exit", side_effect=original),
                ):
                    with self.assertRaises(OSError) as caught:
                        recovery.run_with_provider_preference_recovery(
                            (self.installed_app,), lambda: runner._run_xcodebuild_process_group([], {}, 1),
                            _store=self.preference_store, _recovery_directory=directory,
                            _require_quiescent=lambda first, second: None)
                self.assertIs(caught.exception, original)
                self.assertIsNone(self.preference_store.value)
                self.assertTrue((directory / "pending.json").exists())
                self.preference_store.value = b"synthetic baseline"

    def test_network_audit_failure_fails_the_combined_matrix_execution(self) -> None:
        def audit_matrix_workload(**kwargs: object):
            self.xcresult.mkdir()
            (self.xcresult / "Info.plist").write_bytes(b"result")
            value, _evidence = kwargs["workload"]()
            return value, {"result": "unavailable"}, 1

        with (
            mock.patch.object(runner, "preflight_execution", return_value={"fixture": "stable"}),
            mock.patch.object(runner, "capture_input_snapshot", return_value={"fixture": "stable"}),
            mock.patch.object(runner, "assert_input_snapshot_equal"),
            mock.patch.object(runner, "audit_matrix_workload", side_effect=audit_matrix_workload),
            mock.patch.object(
                runner,
                "_run_xcodebuild_process_group",
                return_value=(0, False),
            ),
            mock.patch.object(
                runner,
                "create_document",
                return_value={
                    "candidate": {"identity_sha256": "d" * 64},
                    "execution": {"result": "passed"},
                    "products": {"xcresult": {"closed_tree_sha256": "c" * 64}},
                    "accessibility_observations": {
                        "observed_selector_projection": [
                            {
                                "observed_identifiers": sorted(
                                    item["requiredIdentifiers"]
                                ),
                                "test_identifier": item["testIdentifier"],
                                "vector_id": item["vectorID"],
                            }
                            for item in load_installed_selector_catalog()
                        ]
                    },
                },
            ),
            mock.patch.object(
                runner,
                "write_create_only",
                side_effect=lambda _path, document: runner.canonical_sha256(document),
            ),
            mock.patch.object(
                runner,
                "_validate_exact_xcresult",
                return_value={
                    "expected_selector_count": 22,
                    "executed_selector_count": 22,
                    "passed_selector_count": 22,
                    "failed_selector_count": 0,
                    "skipped_selector_count": 0,
                    "selectors": [
                        {
                            "test_identifier": item["testIdentifier"],
                            "status": "passed",
                        }
                        for item in load_installed_selector_catalog()
                    ],
                },
            ),
            mock.patch.object(runner, "result_bundle_sha256", return_value="b" * 64),
            mock.patch.object(runner.time, "time", side_effect=[1.0, 1.5]),
        ):
            returncode = runner.main(self.arguments())

        self.assertEqual(returncode, 1)

    def test_runner_source_does_not_maintain_a_second_selector_catalog(self) -> None:
        source = Path(runner.__file__).read_text(encoding="utf-8")
        self.assertIn("load_installed_selector_catalog", source)
        self.assertNotIn("SELECTED_VECTORS.json", source)
        self.assertNotIn("testTask10C", source)

    def test_xcresult_semantics_reject_failure_skip_and_selector_drift(self) -> None:
        selectors = [
            item["testIdentifier"] for item in load_installed_selector_catalog()
        ]

        def tests_document(observed: list[str], *, result: str = "Passed"):
            return {
                "testNodes": [
                    {
                        "nodeType": "UI test bundle",
                        "name": "MacScopeInstalledAppUITests",
                        "children": [
                            {
                                "nodeType": "Test Suite",
                                "name": "WS24InstalledAppUITests",
                                "children": [
                                    {
                                        "nodeType": "Test Case",
                                        "name": identifier.rsplit("/", 1)[-1],
                                        "nodeIdentifier": identifier,
                                        "result": result,
                                        "children": [],
                                    }
                                    for identifier in observed
                                ],
                            }
                        ],
                    }
                ]
            }

        passing_summary = {
            "title": "Test - MacScopeInstalledAppUITests",
            "result": "Passed",
            "totalTestCount": 22,
            "passedTests": 22,
            "failedTests": 0,
            "skippedTests": 0,
            "expectedFailures": 0,
        }
        counts = runner._validate_xcresult_documents(
            passing_summary, tests_document(selectors), selectors
        )
        self.assertEqual(counts["executed_selector_count"], 22)

        failed = dict(passing_summary, result="Failed", passedTests=21, failedTests=1)
        with self.assertRaisesRegex(
            runner.InstalledMatrixReceiptError, "exclusively pass"
        ):
            runner._validate_xcresult_documents(failed, tests_document(selectors), selectors)
        skipped = dict(passing_summary, passedTests=21, skippedTests=1)
        with self.assertRaisesRegex(
            runner.InstalledMatrixReceiptError, "exclusively pass"
        ):
            runner._validate_xcresult_documents(skipped, tests_document(selectors), selectors)
        drifted = selectors[:-1] + ["WS24InstalledAppUITests/testUnexpected()"]
        with self.assertRaisesRegex(
            runner.InstalledMatrixReceiptError, "selectors differ"
        ):
            runner._validate_xcresult_documents(
                passing_summary, tests_document(drifted), selectors
            )

    def test_gate_f_catalog_binds_network_evidence_to_the_exact_matrix_workload(self) -> None:
        from Scripts.reconstruction_gate_f.command_catalog import command_templates

        templates = {item.command_id: item for item in command_templates()}
        workflow = templates["installed.task10-workflow"]
        self.assertIn("installed-network-audit", workflow.command_groups)
        self.assertNotIn("installed.network-acquisition-audit", templates)
        self.assertIn("--network-artifact-root", workflow.argv)
        self.assertNotIn("--duration-seconds", workflow.argv)
        self.assertNotIn(
            "Scripts/reconstruction/audit_installed_network_acquisition.py",
            workflow.argv,
        )
        self.assertEqual(workflow.host.value, "macos-arm64-xcode27-tcc")
        self.assertEqual(workflow.timeout_seconds, 1_800)
        self.assertEqual(
            len(
                [
                    item
                    for item in workflow.argv
                    if item == "Scripts/reconstruction/run_installed_task10_matrix.py"
                ]
            ),
            1,
        )

    def test_runner_rejects_preflight_before_spawning_xcodebuild(self) -> None:
        stderr = io.StringIO()
        with (
            mock.patch.object(
                runner,
                "preflight_execution",
                side_effect=runner.InstalledMatrixReceiptError("sealed preflight refused"),
            ),
            mock.patch.object(runner, "_run_xcodebuild_process_group") as spawn,
            redirect_stderr(stderr),
        ):
            returncode = runner.main(self.arguments())
        self.assertEqual(returncode, 2)
        spawn.assert_not_called()
        self.assertIn("sealed preflight refused", stderr.getvalue())

    def test_timeout_kills_task_owned_process_group_descendant_before_return(self) -> None:
        child_pid_path = self.root / "timeout-child.pid"
        program = (
            "import pathlib,signal,subprocess,sys,time;"
            "signal.signal(signal.SIGTERM,signal.SIG_IGN);"
            "child=subprocess.Popen([sys.executable,'-c',"
            "'import signal,time;signal.signal(signal.SIGTERM,signal.SIG_IGN);time.sleep(60)']);"
            f"pathlib.Path({str(child_pid_path)!r}).write_text(str(child.pid));"
            "time.sleep(60)"
        )
        exit_code, timed_out = runner._run_xcodebuild_process_group(
            [sys.executable, "-c", program],
            dict(os.environ),
            1,
            term_grace_seconds=0.05,
            kill_grace_seconds=2.0,
        )
        self.assertEqual((exit_code, timed_out), (124, True))
        child_pid = int(child_pid_path.read_text(encoding="utf-8"))
        deadline = time.monotonic() + 2.0
        while True:
            try:
                os.kill(child_pid, 0)
            except ProcessLookupError:
                break
            if time.monotonic() >= deadline:
                self.fail("timed-out xcodebuild descendant remained alive")
            time.sleep(0.02)

    def test_permission_error_keeps_process_group_live_until_absence_is_proven(self) -> None:
        with mock.patch.object(
            runner.os,
            "killpg",
            side_effect=[PermissionError(), ProcessLookupError()],
        ):
            self.assertTrue(runner._process_group_exists(901))
            self.assertFalse(runner._process_group_exists(901))

    def test_runner_rejects_symlink_cli_input_before_resolution(self) -> None:
        alias = self.root / "candidate-alias.json"
        alias.symlink_to(self.candidate)
        with self.assertRaisesRegex(runner.InstalledMatrixReceiptError, "non-symlink"):
            runner._non_symlink_existing(alias, name="candidate identity", directory=False)


if __name__ == "__main__":
    unittest.main()
