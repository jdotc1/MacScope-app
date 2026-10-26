from __future__ import annotations

import argparse
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parents[2]
RUNNER = (
    ROOT
    / "Scripts/native-decompiler-xpc/run_installed_native_xpc_gate.py"
)


def load_runner():
    name = "installed_native_xpc_gate_focused_tests"
    specification = importlib.util.spec_from_file_location(name, RUNNER)
    if specification is None or specification.loader is None:
        raise AssertionError("could not load installed native-XPC runner")
    module = importlib.util.module_from_spec(specification)
    sys.modules[name] = module
    specification.loader.exec_module(module)
    return module


class InstalledNativeXPCGateTests(unittest.TestCase):
    def setUp(self) -> None:
        self.module = load_runner()
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name).resolve()
        self.artifacts = self.root / "artifacts"
        self.artifacts.mkdir(mode=0o700)
        self.app = self.root / "MacScope.app"
        self.app.mkdir()
        self.app_executable = self.app / "Contents/MacOS/MacScope"
        self.service_executable = (
            self.app
            / "Contents/XPCServices/NativeDecompilerXPCService.xpc/Contents/MacOS/"
            "NativeDecompilerXPCService"
        )
        for executable in (self.app_executable, self.service_executable):
            executable.parent.mkdir(parents=True, exist_ok=True)
            executable.write_bytes(b"fixture")
            executable.chmod(0o755)
        self.arguments = argparse.Namespace(
            installed_app=self.app,
            candidate_identity=self.root / "candidate.json",
            preparation_receipt=self.root / "NativeLivePreparation.receipt.json",
            artifact_root=self.artifacts,
            qualification_run_id="installed-native-xpc",
            qualification_run_nonce="a" * 64,
            predecessor_observations_sha256="b" * 64,
            phase_timeout_seconds=60,
        )

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def _identity(self, pid: int, path: Path) -> object:
        return self.module.ProcessIdentity(
            pid=pid,
            start_seconds=100 + pid,
            start_microseconds=pid,
            uid=os.geteuid(),
            executable_path=str(path),
        )

    def _authority(self):
        return mock.Mock(
            application_executable=self.app_executable,
            native_executable=self.service_executable,
            native_executable_sha256="c" * 64,
        )

    def test_runner_is_canonical_single_link_executable_and_bytecode_free(self) -> None:
        metadata = RUNNER.lstat()
        self.assertTrue(stat.S_ISREG(metadata.st_mode))
        self.assertFalse(stat.S_ISLNK(metadata.st_mode))
        self.assertEqual(metadata.st_nlink, 1)
        self.assertTrue(metadata.st_mode & stat.S_IXUSR)
        self.assertEqual(RUNNER, RUNNER.resolve(strict=True))

        source = RUNNER.read_text(encoding="utf-8")
        self.assertTrue(source.startswith("#!/usr/bin/python3 -B\n"))
        self.assertLess(
            source.index("sys.dont_write_bytecode = True"),
            source.index("from Scripts.reconstruction import"),
        )
        for forbidden in (
            "xcodebuild",
            "xctestrun",
            "CoreTests",
            "MACSCOPE_NATIVE_DECOMPILER_LIVE_XPC_TESTING",
        ):
            self.assertNotIn(forbidden, source)

        watched = (
            ROOT / "Scripts/native-decompiler-xpc/__pycache__",
            ROOT / "Scripts/reconstruction/__pycache__",
            ROOT / "Scripts/reconstruction_gate_f/__pycache__",
        )

        def snapshot():
            return {
                str(path): (path.stat().st_mtime_ns, path.stat().st_size)
                for directory in watched
                if directory.exists()
                for path in directory.glob("*.pyc")
            }

        before = snapshot()
        environment = os.environ.copy()
        environment.pop("PYTHONDONTWRITEBYTECODE", None)
        result = subprocess.run(
            [str(RUNNER), "--help"],
            check=False,
            capture_output=True,
            text=True,
            env=environment,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(snapshot(), before)

    def test_report_path_is_create_only_before_any_launch(self) -> None:
        report = self.artifacts / self.module.REPORT_NAME
        report.write_text("occupied", encoding="utf-8")
        with self.assertRaisesRegex(
            self.module.InstalledNativeGateError,
            "absent before product launch",
        ):
            self.module._report_path(self.artifacts)

    def test_new_process_admission_rejects_ambiguity_and_wrong_uid(self) -> None:
        baseline = (self._identity(10, self.app_executable),)
        new = self._identity(11, self.app_executable)
        self.assertEqual(
            self.module._wait_for_one_new_process(
                self.app_executable,
                baseline,
                15,
                provider=lambda _: baseline + (new,),
            ),
            new,
        )
        with self.assertRaisesRegex(
            self.module.InstalledNativeGateError,
            "expected one new",
        ):
            self.module._wait_for_one_new_process(
                self.app_executable,
                baseline,
                15,
                provider=lambda _: baseline
                + (new, self._identity(12, self.app_executable)),
            )

        wrong_uid = self.module.ProcessIdentity(
            pid=13,
            start_seconds=113,
            start_microseconds=13,
            uid=os.geteuid() + 1,
            executable_path=str(self.app_executable),
        )
        with self.assertRaisesRegex(
            self.module.InstalledNativeGateError,
            "current-user product",
        ):
            self.module._wait_for_one_new_process(
                self.app_executable,
                baseline,
                15,
                provider=lambda _: baseline + (wrong_uid,),
            )

    def test_dynamic_service_authentication_binds_exact_pid_requirement_and_path(self) -> None:
        identity = self._identity(22, self.service_executable)
        calls: list[list[str]] = []

        def run(argv, **_kwargs):
            calls.append(argv)
            if argv[1:3] == ["-d", "-r-"]:
                return subprocess.CompletedProcess(
                    argv,
                    0,
                    "",
                    "designated => identifier org.macscope.app.NativeDecompiler and anchor apple generic\n",
                )
            if argv[1:] == ["-dvvv", "+22"]:
                return subprocess.CompletedProcess(
                    argv,
                    0,
                    "",
                    "Identifier=org.macscope.app.NativeDecompiler\n"
                    "TeamIdentifier=TEAM000000\n"
                    "CodeDirectory v=20500 flags=0x10000(runtime)\n",
                )
            return subprocess.CompletedProcess(argv, 0, "", "")

        with (
            mock.patch.object(self.module, "_libproc", return_value=object()),
            mock.patch.object(self.module, "_observe_process", return_value=identity),
            mock.patch.object(self.module, "_run", side_effect=run),
        ):
            observed = self.module._authenticate_service_process(
                identity,
                self.service_executable,
                self.service_executable.parents[2],
                15,
            )
        self.assertEqual(observed, identity)
        dynamic = next(
            argv
            for argv in calls
            if any(item.startswith("-R=") for item in argv)
        )
        self.assertEqual(dynamic[-1], "+22")
        requirement = next(item for item in dynamic if item.startswith("-R="))
        self.assertIn("org.macscope.app.NativeDecompiler", requirement)

    def test_fallback_probe_rejects_any_new_service_process(self) -> None:
        authority = self._authority()
        app = self._identity(30, self.app_executable)
        unexpected = self._identity(31, self.service_executable)
        with (
            mock.patch.object(self.module, "_launch_app", return_value=(app, ())),
            mock.patch.object(self.module, "_open_candidate_binary"),
            mock.patch.object(
                self.module,
                "_observe_accessibility",
                return_value=("Pending, MacScope fallback: ordinary output", False),
            ),
            mock.patch.object(
                self.module,
                "matching_processes",
                return_value=(unexpected,),
            ),
            mock.patch.object(self.module, "_terminate_owned"),
        ):
            with self.assertRaisesRegex(
                self.module.InstalledNativeGateError,
                "created or replaced",
            ):
                self.module._fallback_probe(authority, self.app, (), 15)

    def test_gate_writes_only_the_closed_canonical_report_after_both_proofs(self) -> None:
        authority = self._authority()
        app = self._identity(40, self.app_executable)
        service = self._identity(41, self.service_executable)
        native = self.module.ProductProbe(
            app=app,
            service=service,
            status="Ready, ghidra-native-decompiler, engine 12.1.2",
        )
        fallback = self.module.ProductProbe(
            app=self._identity(42, self.app_executable),
            service=None,
            status="Pending, MacScope fallback: ordinary pseudocode",
        )
        with (
            mock.patch.object(
                self.module.preparation,
                "validate_installed_release",
                return_value=authority,
            ),
            mock.patch.object(
                self.module.preparation,
                "require_unchanged_installed_release",
            ) as unchanged,
            mock.patch.object(self.module, "matching_processes", return_value=()),
            mock.patch.object(self.module, "_native_probe", return_value=native),
            mock.patch.object(self.module, "_fallback_probe", return_value=fallback),
            mock.patch.object(self.module, "_terminate_owned"),
            mock.patch.object(self.module, "_wait_process_exit", return_value=True),
        ):
            observed_native, observed_fallback, report = self.module.run_gate(
                self.arguments
            )

        self.assertEqual(observed_native, native)
        self.assertEqual(observed_fallback, fallback)
        self.assertEqual(report, self.artifacts / self.module.REPORT_NAME)
        self.assertEqual(unchanged.call_count, 2)
        document = json.loads(report.read_text(encoding="utf-8"))
        self.assertEqual(
            set(document),
            {
                "ended_at_unix_ms",
                "exit_code",
                "predecessor_observations_sha256",
                "qualification_run",
                "result",
                "schema_version",
                "started_at_unix_ms",
                "stress",
            },
        )
        self.assertEqual(document["schema_version"], 2)
        self.assertEqual(document["result"], "passed")
        self.assertEqual(document["exit_code"], 0)
        self.assertIsNone(document["stress"])

        with mock.patch.object(
            self.module.preparation,
            "validate_installed_release",
        ) as validator:
            with self.assertRaisesRegex(
                self.module.InstalledNativeGateError,
                "absent before product launch",
            ):
                self.module.run_gate(self.arguments)
        validator.assert_not_called()

    def test_postpublication_authority_failure_removes_favorable_report(self) -> None:
        authority = self._authority()
        native = self.module.ProductProbe(
            app=self._identity(50, self.app_executable),
            service=self._identity(51, self.service_executable),
            status="Ready, provider, engine 1",
        )
        fallback = self.module.ProductProbe(
            app=self._identity(52, self.app_executable),
            service=None,
            status="Pending, MacScope fallback: ordinary pseudocode",
        )
        with (
            mock.patch.object(
                self.module.preparation,
                "validate_installed_release",
                return_value=authority,
            ),
            mock.patch.object(
                self.module.preparation,
                "require_unchanged_installed_release",
                side_effect=[None, self.module.preparation.PreparationReceiptError("drift")],
            ),
            mock.patch.object(self.module, "matching_processes", return_value=()),
            mock.patch.object(self.module, "_native_probe", return_value=native),
            mock.patch.object(self.module, "_fallback_probe", return_value=fallback),
            mock.patch.object(self.module, "_same_live_process", return_value=True),
            mock.patch.object(self.module, "_terminate_owned"),
            mock.patch.object(self.module, "_wait_process_exit", return_value=True),
        ):
            with self.assertRaisesRegex(
                self.module.preparation.PreparationReceiptError,
                "drift",
            ):
                self.module.run_gate(self.arguments)
        self.assertFalse((self.artifacts / self.module.REPORT_NAME).exists())

    def test_success_stdout_order_is_frozen(self) -> None:
        native = self.module.ProductProbe(
            app=self._identity(60, self.app_executable),
            service=self._identity(61, self.service_executable),
            status="Ready, provider, engine 1",
        )
        fallback = self.module.ProductProbe(
            app=self._identity(62, self.app_executable),
            service=None,
            status="Pending, MacScope fallback: ordinary pseudocode",
        )
        report = self.artifacts / self.module.REPORT_NAME
        argv = [
            "--installed-app",
            str(self.app),
            "--candidate-identity",
            str(self.arguments.candidate_identity),
            "--preparation-receipt",
            str(self.arguments.preparation_receipt),
            "--artifact-root",
            str(self.artifacts),
            "--qualification-run-id",
            self.arguments.qualification_run_id,
            "--qualification-run-nonce",
            self.arguments.qualification_run_nonce,
            "--predecessor-observations-sha256",
            self.arguments.predecessor_observations_sha256,
            "--phase-timeout-seconds",
            "60",
        ]
        stdout = io.StringIO()
        with (
            mock.patch.object(
                self.module,
                "run_gate",
                return_value=(native, fallback, report),
            ),
            contextlib.redirect_stdout(stdout),
        ):
            status = self.module.main(argv, _allow_test_app=True)
        self.assertEqual(status, 0)
        lines = stdout.getvalue().splitlines()
        self.assertEqual(lines[0], f"MACSCOPE_INSTALLED_NATIVE_APP={self.app}")
        self.assertEqual(
            lines[1],
            f"MACSCOPE_SIGNED_NATIVE_EXECUTABLE={self.service_executable}",
        )
        self.assertEqual(lines[2], "MACSCOPE_INSTALLED_NATIVE_APP_PID=60")
        self.assertEqual(lines[3], "MACSCOPE_INSTALLED_NATIVE_SERVICE_PID=61")
        self.assertTrue(lines[4].startswith("MACSCOPE_INSTALLED_NATIVE_RESPONSE_STATUS_SHA256="))
        self.assertTrue(lines[5].startswith("MACSCOPE_INSTALLED_NATIVE_FALLBACK_STATUS_SHA256="))
        self.assertEqual(
            lines[6],
            f"MACSCOPE_SIGNED_NATIVE_EXECUTION_REPORT={report}",
        )
        self.assertEqual(lines[7], "PASS: installed native XPC gate")


if __name__ == "__main__":
    unittest.main()
