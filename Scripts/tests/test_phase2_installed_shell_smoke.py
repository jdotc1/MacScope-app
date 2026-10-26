#!/usr/bin/env python3

from __future__ import annotations

import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import stat
import tempfile
import unittest
from unittest import mock


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
SCRIPT = REPOSITORY_ROOT / "Scripts" / "phase2" / "run_installed_shell_smoke.py"


def load_module():
    specification = importlib.util.spec_from_file_location(
        "phase2_installed_shell_smoke",
        SCRIPT,
    )
    if specification is None or specification.loader is None:
        raise AssertionError("could not load installed shell smoke script")
    module = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(module)
    return module


installed_shell_smoke = load_module()


class Phase2InstalledShellSmokeScriptTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary_directory.name)
        self.app = self.root / "MacScope.app"
        self.executable = self.app / "Contents" / "MacOS" / "MacScope"
        self.broker = (
            self.app
            / "Contents"
            / "XPCServices"
            / "ShellBrokerXPCService.xpc"
            / "Contents"
            / "MacOS"
            / "ShellBrokerXPCService"
        )
        self.output = self.root / "report.json"
        self.marker = "script-test-marker"
        self.source_commit = "936ee921a1d431ebe9d67e36957144e4775a1cf8"
        self.source_tree = "1" * 40
        self.executable.parent.mkdir(parents=True)
        self.broker.parent.mkdir(parents=True)
        self.executable.write_bytes(b"fake app executable")
        self.broker.write_bytes(b"fake shell broker executable")
        self.provenance = (
            self.app / "Contents" / "Resources" / installed_shell_smoke.PROVENANCE_NAME
        )
        self.provenance.parent.mkdir(parents=True)
        self.provenance.write_text(
            json.dumps({
                "schema_version": 1,
                "qualification_eligible": True,
                "configuration": "Release",
                "git_head_commit": self.source_commit,
                "git_head_tree": self.source_tree,
                "repository_clean": True,
                "ghostty_surface_compilation_condition": "MACSCOPE_FULL_GHOSTTY_SURFACE",
            }, sort_keys=True),
            encoding="utf-8",
        )

    def tearDown(self) -> None:
        self.temporary_directory.cleanup()

    def test_accepts_successful_app_emitted_report(self) -> None:
        result = self.run_command()

        self.assertEqual(result["accepted"], True)
        self.assertEqual(result["app"], str(self.app))
        self.assertEqual(result["report"], str(self.output))
        self.assertEqual(result["reportSHA256"], self.sha256(self.output))
        self.assertEqual(
            result["legacyGridReport"],
            str(self.output.with_name("report.legacy-grid.json")),
        )
        self.assertEqual(result["sourceCommit"], self.source_commit)
        self.assertEqual(result["brokerExecutableSHA256"], self.sha256(self.broker))

    def test_bridge_invocation_derives_commit_from_installed_provenance(self) -> None:
        result = self.run_command(include_expected_commit=False)

        self.assertEqual(result["accepted"], True)
        self.assertEqual(result["sourceCommit"], self.source_commit)

    def test_rejects_report_without_expected_marker_reply(self) -> None:
        with self.assertRaisesRegex(installed_shell_smoke.SmokeError, "expected shell reply"):
            self.run_command(report_overrides={"observedReply": "reply:wrong-marker"})

    def test_rejects_report_without_reconnect_proof(self) -> None:
        with self.assertRaisesRegex(installed_shell_smoke.SmokeError, "reconnect event"):
            self.run_command(report_overrides={"reconnectAcceptedTranscriptEventCount": 0})

    def test_rejects_installed_provenance_for_another_candidate(self) -> None:
        payload = json.loads(self.provenance.read_text(encoding="utf-8"))
        payload["git_head_commit"] = "f" * 40
        self.provenance.write_text(json.dumps(payload, sort_keys=True), encoding="utf-8")

        with self.assertRaisesRegex(installed_shell_smoke.SmokeError, "exact renderer candidate"):
            self.run_command()

    def test_rejects_transcript_only_fallback_as_legacy_grid_proof(self) -> None:
        with self.assertRaisesRegex(installed_shell_smoke.SmokeError, "transcript-only fallback"):
            self.run_command(renderer_overrides={
                installed_shell_smoke.FORCED_LEGACY_GRID_MODE: {
                    "transcriptOnlyFallbackPresented": True,
                }
            })

    def test_rejects_renderer_evidence_for_another_shell_process(self) -> None:
        with self.assertRaisesRegex(installed_shell_smoke.SmokeError, "ShellBroker process"):
            self.run_command(renderer_overrides={
                installed_shell_smoke.DEFAULT_FULL_SURFACE_MODE: {
                    "shellProcessIdentifier": 99999,
                }
            })

    def test_rejects_full_surface_when_legacy_grid_was_requested(self) -> None:
        with self.assertRaisesRegex(installed_shell_smoke.SmokeError, "requested renderer backend"):
            self.run_command(renderer_overrides={
                installed_shell_smoke.FORCED_LEGACY_GRID_MODE: {
                    "selectedBackend": "ghosttyFullSurface",
                    "fallbackReason": None,
                }
            })

    def test_rejects_missing_shell_broker_before_launch(self) -> None:
        self.broker.unlink()

        with mock.patch.object(installed_shell_smoke.subprocess, "run") as mocked_run:
            with self.assertRaisesRegex(installed_shell_smoke.SmokeError, "ShellBroker executable"):
                self.run_command()

        mocked_run.assert_not_called()

    def run_command(
        self,
        report_overrides: dict[str, object] | None = None,
        renderer_overrides: dict[str, dict[str, object]] | None = None,
        include_expected_commit: bool = True,
    ) -> dict[str, object]:
        def fake_run(*_: object, **kwargs: object) -> subprocess.CompletedProcess[str]:
            environment = dict(kwargs["env"])  # type: ignore[arg-type]
            renderer_mode = environment[installed_shell_smoke.RENDERER_MODE_ENV]
            report = self.report_payload(renderer_mode)
            if report_overrides:
                report.update(report_overrides)
            if renderer_overrides and renderer_mode in renderer_overrides:
                evidence = dict(report["rendererEvidence"])  # type: ignore[arg-type]
                evidence.update(renderer_overrides[renderer_mode])
                report["rendererEvidence"] = evidence
            Path(environment[installed_shell_smoke.REPORT_ENV]).write_text(
                json.dumps(report, sort_keys=True), encoding="utf-8"
            )
            return subprocess.CompletedProcess(args=[str(self.executable)], returncode=0, stdout="", stderr="")

        arguments_list = [
            "--app",
            str(self.app),
            "--output",
            str(self.output),
            "--marker",
            self.marker,
            "--single-launch",
        ]
        if include_expected_commit:
            arguments_list.extend(["--expected-source-commit", self.source_commit])
        arguments = installed_shell_smoke.parse_arguments(arguments_list)
        with mock.patch.object(installed_shell_smoke.subprocess, "run", side_effect=fake_run):
            return installed_shell_smoke.run_smoke(arguments)

    def report_payload(
        self,
        renderer_mode: str = installed_shell_smoke.DEFAULT_FULL_SURFACE_MODE,
    ) -> dict[str, object]:
        backend, fallback = {
            installed_shell_smoke.DEFAULT_FULL_SURFACE_MODE: ("ghosttyFullSurface", None),
            installed_shell_smoke.FORCED_LEGACY_GRID_MODE: (
                "macScopeGhosttyVTGrid", "recoveryOverride"
            ),
        }[renderer_mode]
        return {
            "acceptedTranscriptEventCount": 3,
            "appExecutablePath": str(self.executable),
            "appExecutableSHA256": self.sha256(self.executable),
            "cleanupObservedProcessAbsent": True,
            "error": None,
            "generatedAtUnixMilliseconds": 1,
            "launchedProcessIdentifier": 12345,
            "observedReply": f"reply:{self.marker}",
            "reconnectAcceptedTranscriptEventCount": 1,
            "schemaVersion": installed_shell_smoke.REPORT_SCHEMA_VERSION,
            "sourceCommit": self.source_commit,
            "sourceTree": self.source_tree,
            "buildProvenanceSHA256": self.sha256(self.provenance),
            "rendererEvidence": {
                "requestedMode": renderer_mode,
                "selectedBackend": backend,
                "fallbackReason": fallback,
                "rendererPresented": True,
                "transcriptOnlyFallbackPresented": False,
                "shellSessionID": "10000000-0000-0000-0000-000000000010",
                "shellRequestID": "10000000-0000-0000-0000-000000000011",
                "shellProcessIdentifier": 12345,
            },
            "shellBrokerServiceIdentifier": "terminal.human_pty.shell_broker",
            "shellBrokerWireProtocol": "macscope.phase2.shell_broker.xpc.v4",
            "status": "passed",
            "supportedCommands": [
                "launchProcess",
                "cleanupProcess",
                "writeInput",
                "resizeTerminal",
                "sendSignal",
                "pollTranscript",
                "reconnectSession",
                "launchDurableProcess",
                "commitDurableSession",
                "durableSessionStatus",
                "attachDurableSession",
                "detachDurableSession",
                "heartbeatDurableSession",
            ],
        }

    def test_restart_gate_requires_wait_beyond_old_grace(self) -> None:
        arguments = installed_shell_smoke.parse_arguments([
            "--app", str(self.app),
            "--output", str(self.output),
            "--restart-wait-seconds", "120",
            "--expected-source-commit", self.source_commit,
        ])
        with self.assertRaisesRegex(installed_shell_smoke.SmokeError, "must exceed"):
            installed_shell_smoke.run_restart_smoke(arguments)

    def test_restart_report_requires_exact_identity_and_cleanup(self) -> None:
        report = self.restart_report("RESUME")
        installed_shell_smoke.validate_restart_report(
            report, self.executable, self.marker, "RESUME",
            self.build_identity(), installed_shell_smoke.FORCED_LEGACY_GRID_MODE,
        )
        report["processStartTimeUnixNanoseconds"] = 0
        with self.assertRaisesRegex(installed_shell_smoke.SmokeError, "start time"):
            installed_shell_smoke.validate_restart_report(
                report, self.executable, self.marker, "RESUME",
                self.build_identity(), installed_shell_smoke.FORCED_LEGACY_GRID_MODE,
            )

    def test_restart_report_rejects_unadvanced_cursor_or_missing_buffered_marker(self) -> None:
        report = self.restart_report("RESUME")
        report["transcriptCursor"] = 1
        with self.assertRaisesRegex(installed_shell_smoke.SmokeError, "did not advance"):
            installed_shell_smoke.validate_restart_report(
                report, self.executable, self.marker, "RESUME",
                self.build_identity(), installed_shell_smoke.FORCED_LEGACY_GRID_MODE,
            )
        report = self.restart_report("RESUME")
        report["bufferedMarkerAcceptedCount"] = 0
        with self.assertRaisesRegex(installed_shell_smoke.SmokeError, "exactly once"):
            installed_shell_smoke.validate_restart_report(
                report, self.executable, self.marker, "RESUME",
                self.build_identity(), installed_shell_smoke.FORCED_LEGACY_GRID_MODE,
            )

    def test_rendezvous_permission_check_rejects_group_read(self) -> None:
        rendezvous = self.root / "resume.rendezvous.json"
        rendezvous.write_text("{}", encoding="utf-8")
        rendezvous.chmod(stat.S_IRUSR | stat.S_IWUSR | stat.S_IRGRP)
        self.assertNotEqual(rendezvous.stat().st_mode & 0o777, 0o600)

    def test_restart_gate_launches_explicit_prepare_and_resume_modes(self) -> None:
        arguments = installed_shell_smoke.parse_arguments([
            "--app", str(self.app),
            "--output", str(self.output),
            "--marker", self.marker,
            "--restart-wait-seconds", "121",
            "--expected-source-commit", self.source_commit,
        ])
        prepare_report = self.restart_report("PREPARE")
        resume_report = self.restart_report("RESUME")
        observed_environments: list[dict[str, str]] = []

        class FakePopen:
            pid = 777

            def poll(self) -> None:
                return None

        def fake_popen(*_: object, **kwargs: object) -> FakePopen:
            observed_environments.append(dict(kwargs["env"]))  # type: ignore[arg-type]
            return FakePopen()

        def fake_wait(path: Path, *_: object) -> dict[str, object]:
            rendezvous = self.output.with_name(f"{self.output.stem}.rendezvous.json")
            rendezvous.write_text("{}", encoding="utf-8")
            rendezvous.chmod(0o600)
            path.write_text(json.dumps(prepare_report), encoding="utf-8")
            return prepare_report

        def fake_run(*_: object, **kwargs: object) -> subprocess.CompletedProcess[str]:
            observed_environments.append(dict(kwargs["env"]))  # type: ignore[arg-type]
            self.output.write_text(json.dumps(resume_report), encoding="utf-8")
            self.output.with_name(f"{self.output.stem}.rendezvous.json").unlink()
            return subprocess.CompletedProcess(args=[str(self.executable)], returncode=0, stdout="", stderr="")

        with mock.patch.object(installed_shell_smoke.subprocess, "Popen", side_effect=fake_popen), \
             mock.patch.object(installed_shell_smoke, "wait_for_report", side_effect=fake_wait), \
             mock.patch.object(installed_shell_smoke, "stop_prepare_cooperatively"), \
             mock.patch.object(installed_shell_smoke, "process_start_identity", return_value="Mon Jul 20 03:00:00 2026"), \
             mock.patch.object(installed_shell_smoke.time, "sleep"), \
             mock.patch.object(installed_shell_smoke.subprocess, "run", side_effect=fake_run), \
             mock.patch.object(installed_shell_smoke, "process_executable_path", return_value=None), \
             mock.patch.object(installed_shell_smoke, "capture_bounded_logs"):
            result = installed_shell_smoke.run_restart_smoke(arguments)

        self.assertTrue(result["accepted"])
        self.assertEqual(observed_environments[0][installed_shell_smoke.MODE_ENV], "PREPARE")
        self.assertEqual(observed_environments[1][installed_shell_smoke.MODE_ENV], "RESUME")
        self.assertEqual(
            observed_environments[0][installed_shell_smoke.RENDEZVOUS_ENV],
            observed_environments[1][installed_shell_smoke.RENDEZVOUS_ENV],
        )

    def test_cooperative_stop_rejects_symlink(self) -> None:
        target = self.root / "target"
        target.touch(mode=0o600)
        sentinel = self.root / "stop"
        sentinel.symlink_to(target)
        with self.assertRaisesRegex(installed_shell_smoke.SmokeError, "sentinel"):
            installed_shell_smoke.create_cooperative_stop(sentinel)

    def test_cooperative_stop_atomically_creates_0600_and_reaps(self) -> None:
        process = mock.Mock()
        process.poll.return_value = None
        process.wait.return_value = 0
        sentinel = self.root / "cooperative.stop"
        installed_shell_smoke.stop_prepare_cooperatively(process, sentinel)
        self.assertEqual(sentinel.stat().st_mode & 0o777, 0o600)
        process.wait.assert_called_once()

    def test_log_capture_rejects_command_failure_without_artifact(self) -> None:
        destination = self.root / "logs.json"
        failed = subprocess.CompletedProcess(args=[], returncode=1, stdout=b"", stderr=b"denied")
        with mock.patch.object(installed_shell_smoke.subprocess, "run", return_value=failed):
            with self.assertRaisesRegex(installed_shell_smoke.SmokeError, "log capture failed"):
                installed_shell_smoke.capture_bounded_logs(
                    installed_shell_smoke.datetime.now(installed_shell_smoke.timezone.utc),
                    destination,
                    self.marker,
                    {777},
                )
        self.assertFalse(destination.exists())

    def test_log_capture_refuses_symlink_destination(self) -> None:
        target = self.root / "log-target"
        destination = self.root / "logs.json"
        destination.symlink_to(target)
        succeeded = subprocess.CompletedProcess(args=[], returncode=0, stdout=b"event\n", stderr=b"")
        with mock.patch.object(installed_shell_smoke.subprocess, "run", return_value=succeeded):
            with self.assertRaisesRegex(installed_shell_smoke.SmokeError, "atomically create"):
                installed_shell_smoke.capture_bounded_logs(
                    installed_shell_smoke.datetime.now(installed_shell_smoke.timezone.utc),
                    destination,
                    self.marker,
                    {777},
                )
        self.assertFalse(target.exists())

    def test_start_identity_failure_still_uses_readable_rendezvous_cleanup(self) -> None:
        arguments = installed_shell_smoke.parse_arguments([
            "--app", str(self.app), "--output", str(self.output),
            "--restart-wait-seconds", "121",
            "--expected-source-commit", self.source_commit,
        ])
        rendezvous = self.output.with_name(f"{self.output.stem}.rendezvous.json")
        observed_modes: list[str] = []
        process = mock.Mock()
        process.pid = 779
        process.poll.return_value = None

        def fail_start(_: int) -> None:
            rendezvous.write_text("{}", encoding="utf-8")
            rendezvous.chmod(0o600)
            return None

        def cleanup_run(*_: object, **kwargs: object) -> subprocess.CompletedProcess[str]:
            environment = dict(kwargs["env"])  # type: ignore[arg-type]
            observed_modes.append(environment[installed_shell_smoke.MODE_ENV])
            cleanup_path = Path(environment[installed_shell_smoke.REPORT_ENV])
            cleanup_path.write_text(json.dumps(self.restart_report("CLEANUP")), encoding="utf-8")
            rendezvous.unlink()
            return subprocess.CompletedProcess(args=[], returncode=0, stdout="", stderr="")

        with mock.patch.object(installed_shell_smoke.subprocess, "Popen", return_value=process), \
             mock.patch.object(installed_shell_smoke, "process_start_identity", side_effect=fail_start), \
             mock.patch.object(installed_shell_smoke.subprocess, "run", side_effect=cleanup_run), \
             mock.patch.object(installed_shell_smoke, "stop_prepare_cooperatively"):
            with self.assertRaisesRegex(installed_shell_smoke.SmokeError, "start identity"):
                installed_shell_smoke.run_restart_smoke(arguments)
        self.assertEqual(observed_modes, ["CLEANUP"])

    def test_resume_failure_invokes_authenticated_cleanup_mode(self) -> None:
        arguments = installed_shell_smoke.parse_arguments([
            "--app", str(self.app), "--output", str(self.output),
            "--restart-wait-seconds", "121",
            "--expected-source-commit", self.source_commit,
        ])
        observed_modes: list[str] = []

        class FakePopen:
            pid = 778

            def poll(self) -> None:
                return None

        def fake_wait(path: Path, *_: object) -> dict[str, object]:
            report = self.restart_report("PREPARE")
            path.write_text(json.dumps(report), encoding="utf-8")
            rendezvous = self.output.with_name(f"{self.output.stem}.rendezvous.json")
            rendezvous.write_text("{}", encoding="utf-8")
            rendezvous.chmod(0o600)
            return report

        def fake_run(*_: object, **kwargs: object) -> subprocess.CompletedProcess[str]:
            environment = dict(kwargs["env"])  # type: ignore[arg-type]
            mode = environment[installed_shell_smoke.MODE_ENV]
            observed_modes.append(mode)
            if mode == "RESUME":
                return subprocess.CompletedProcess(args=[], returncode=2, stdout="", stderr="resume failed")
            cleanup_path = Path(environment[installed_shell_smoke.REPORT_ENV])
            cleanup_path.write_text(json.dumps(self.restart_report("CLEANUP")), encoding="utf-8")
            self.output.with_name(f"{self.output.stem}.rendezvous.json").unlink()
            return subprocess.CompletedProcess(args=[], returncode=0, stdout="", stderr="")

        with mock.patch.object(installed_shell_smoke.subprocess, "Popen", return_value=FakePopen()), \
             mock.patch.object(installed_shell_smoke, "wait_for_report", side_effect=fake_wait), \
             mock.patch.object(installed_shell_smoke, "stop_prepare_cooperatively"), \
             mock.patch.object(installed_shell_smoke, "process_start_identity", return_value="captured-start"), \
             mock.patch.object(installed_shell_smoke.time, "sleep"), \
             mock.patch.object(installed_shell_smoke.subprocess, "run", side_effect=fake_run):
            with self.assertRaisesRegex(installed_shell_smoke.SmokeError, "RESUME app exited"):
                installed_shell_smoke.run_restart_smoke(arguments)
        self.assertEqual(observed_modes, ["RESUME", "CLEANUP"])

    def restart_report(self, mode: str) -> dict[str, object]:
        renderer_mode = (
            installed_shell_smoke.DEFAULT_FULL_SURFACE_MODE
            if mode == "PREPARE"
            else installed_shell_smoke.FORCED_LEGACY_GRID_MODE
        )
        report = self.report_payload(renderer_mode)
        cleanup = mode in ("RESUME", "CLEANUP")
        report.update({
            "acceptedTranscriptEventCount": 1 if mode == "RESUME" else 0,
            "cleanupObservedProcessAbsent": cleanup,
            "mode": mode,
            "brokerIncarnationID": "10000000-0000-0000-0000-000000000001",
            "processStartTimeUnixNanoseconds": 42,
            "executablePath": "/bin/sh",
            "processGroupIdentifier": 12345,
            "transcriptCursor": 2 if mode == "RESUME" else 1,
            "bufferedMarker": f"detached:{self.marker}" if mode == "RESUME" else None,
            "bufferedMarkerAcceptedCount": 1 if mode == "RESUME" else 0,
            "transcriptCursorAdvanced": mode == "RESUME",
            "capabilityRemoved": cleanup,
            "rendezvousRemoved": cleanup,
            "observedReply": f"detached:{self.marker}" if mode == "RESUME" else None,
            "reconnectAcceptedTranscriptEventCount": 0,
        })
        return report

    def build_identity(self) -> dict[str, str]:
        return {
            "sourceCommit": self.source_commit,
            "sourceTree": self.source_tree,
            "buildProvenanceSHA256": self.sha256(self.provenance),
        }

    @staticmethod
    def sha256(path: Path) -> str:
        return hashlib.sha256(path.read_bytes()).hexdigest()


if __name__ == "__main__":
    unittest.main()
