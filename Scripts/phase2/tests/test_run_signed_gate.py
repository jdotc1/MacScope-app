#!/usr/bin/env python3

from __future__ import annotations

import json
import importlib.util
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import textwrap
import unittest
from unittest import mock


SCRIPT = Path(__file__).resolve().parents[1] / "run_signed_gate.py"
SPEC = importlib.util.spec_from_file_location("run_signed_gate", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
run_signed_gate = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(run_signed_gate)


class RunSignedGateTests(unittest.TestCase):
    def test_profile_parser_is_closed_and_rejects_duplicate_and_abbreviated_options(self) -> None:
        required = ["--candidate-app", "/tmp/a.app", "--stdout-log", "/tmp/o", "--stderr-log", "/tmp/e"]
        self.assertEqual(run_signed_gate.parse_arguments(required).profile, "historical-f4c")
        self.assertEqual(run_signed_gate.parse_arguments(required + ["--profile", "qwen38-v2-q6k"]).profile, "qwen38-v2-q6k")
        for options in [["--profile=unknown"], ["--prof=qwen38-v2-q6k"],
                        ["--profile=qwen38-v2-q6k", "--profile=historical-f4c"],
                        ["--profile", "qwen38-v2-q6k "]]:
            with self.subTest(options=options), self.assertRaises(SystemExit):
                run_signed_gate.parse_arguments(required + options)

    def test_candidate_profile_authority_requires_closed_schema_and_source_identity(self) -> None:
        record = {
            "schema_version": 2, "status": "authority-verified",
            "profile_selector": "qwen38-v2-q6k", "admission_state": "unqualified",
            "qualification_definition_sha256": "d" * 64,
            "app_executable_sha256": "a" * 64, "worker_executable_sha256": "b" * 64,
            "git_head_commit": "c" * 40,
        }
        def encoded(value):
            return json.dumps(value, sort_keys=True, separators=(",", ":")).encode() + b"\n"
        run_signed_gate.validate_terminal_record(encoded(record), b"", "authority", "qwen38-v2-q6k", {"app_executable_sha256": "a" * 64})
        for changes in [{"schema_version": 1}, {"profile_selector": "historical-f4c"},
                        {"admission_state": "qualified"}, {"provider_build_sha256": None},
                        {"qualification_definition_sha256": "bad"}]:
            with self.subTest(changes=changes), self.assertRaises(run_signed_gate.LaunchError):
                run_signed_gate.validate_terminal_record(encoded(dict(record, **changes)), b"", "authority", "qwen38-v2-q6k")
        with self.assertRaises(run_signed_gate.LaunchError):
            run_signed_gate.validate_terminal_record(encoded(record), b"", "authority", "qwen38-v2-q6k", {"app_executable_sha256": "f" * 64})
        with self.assertRaises(run_signed_gate.LaunchError):
            run_signed_gate.validate_terminal_record(encoded(record), b"", "authority")

    def test_candidate_profile_invocation_adds_only_one_selector_argument(self) -> None:
        process = mock.Mock(pid=42, returncode=0)
        with mock.patch.object(run_signed_gate.subprocess, "Popen", return_value=process) as launch:
            run_signed_gate.invoke_once(Path("/tmp/app"), None, "authority", {}, 1,
                                       mock.Mock(), mock.Mock(), "qwen38-v2-q6k")
        self.assertEqual(launch.call_args.args[0], ["/tmp/app", run_signed_gate.AUTHORITY_ARGUMENT,
                                                  "--phase2-f4c-profile=qwen38-v2-q6k"])

    def test_candidate_canary_binds_fresh_authority_definition_and_retains_separate_logs(self) -> None:
        worker = self.app / "Contents/XPCServices/AIAgentWorkerXPCService.xpc/Contents/MacOS/AIAgentWorkerXPCService"
        worker.parent.mkdir(parents=True)
        worker.write_bytes(b"synthetic worker identity")
        provenance = self.app / "Contents/Resources/MacScopeBuildProvenance.json"
        provenance.parent.mkdir(parents=True)
        provenance.write_text(json.dumps({"git_head_commit": "c" * 40}))
        self.write_candidate('''
            import hashlib, json, sys
            from pathlib import Path
            app = Path(__file__).resolve().parents[2]
            root = app.parent
            with (root / "calls.jsonl").open("a") as calls:
                calls.write(json.dumps(sys.argv[1:]) + "\\n")
            record = {
                "schema_version": 2, "profile_selector": "qwen38-v2-q6k",
                "qualification_definition_sha256": "d" * 64,
                "app_executable_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
                "worker_executable_sha256": hashlib.sha256((app / "Contents/XPCServices/AIAgentWorkerXPCService.xpc/Contents/MacOS/AIAgentWorkerXPCService").read_bytes()).hexdigest(),
                "git_head_commit": "c" * 40,
            }
            if sys.argv[1] == "--phase2-f4c-gate-authority-proof":
                record.update(status="authority-verified", admission_state="unqualified")
            else:
                record.update(status="canary-completed", admission_state="canary-passed",
                    provider_build_sha256="e" * 64, runtime_closure_sha256="f" * 64,
                    template_authority_sha256="a" * 64, canary_evidence_sha256="b" * 64,
                    run_id="01234567-89ab-cdef-0123-456789abcdef",
                    evidence_location="MacScope/Qualification/F4C/01234567-89ab-cdef-0123-456789abcdef/canary.json")
                if (root / "mismatch").exists():
                    record["qualification_definition_sha256"] = "e" * 64
            print(json.dumps(record, sort_keys=True, separators=(",", ":")))
        ''')
        result = self.run_launcher("--profile", "qwen38-v2-q6k", "--mode", "canary")
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = [json.loads(line) for line in (self.root / "calls.jsonl").read_text().splitlines()]
        self.assertEqual([call[0] for call in calls], [run_signed_gate.AUTHORITY_ARGUMENT, run_signed_gate.CANARY_ARGUMENT])
        self.assertTrue(self.stdout_log.with_name("stdout.log.authority").is_file())
        self.assertEqual(json.loads(result.stdout)["qualification_definition_sha256"], "d" * 64)
        (self.root / "mismatch").write_text("synthetic drift")
        self.stdout_log = self.root / "second.stdout"
        self.stderr_log = self.root / "second.stderr"
        failed = self.run_launcher("--profile", "qwen38-v2-q6k", "--mode", "canary")
        self.assertNotEqual(failed.returncode, 0)
        self.assertIn("source app identity mismatch", failed.stderr)

    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary_directory.name)
        self.app = self.root / "MacScope.app"
        self.executable = self.app / "Contents" / "MacOS" / "MacScope"
        self.executable.parent.mkdir(parents=True)
        self.stdout_log = self.root / "stdout.log"
        self.stderr_log = self.root / "stderr.log"

    def tearDown(self) -> None:
        self.temporary_directory.cleanup()

    def test_authority_is_default_and_uses_minimal_environment_without_live_opt_in(self) -> None:
        self.write_candidate(
            """
            import json, os
            from pathlib import Path
            root = Path(__file__).resolve().parents[3]
            (root / "arguments.json").write_text(json.dumps(__import__("sys").argv[1:]))
            (root / "environment.json").write_text(json.dumps(dict(os.environ), sort_keys=True))
            print('{"app_executable_sha256":"a","git_head_commit":"b",'
                  '"schema_version":1,"status":"authority-verified",'
                  '"worker_executable_sha256":"c"}')
            """
        )

        result = self.run_launcher()

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            json.loads((self.root / "arguments.json").read_text()),
            ["--phase2-f4c-gate-authority-proof"],
        )
        environment = json.loads((self.root / "environment.json").read_text())
        self.assertNotIn("MACSCOPE_RUN_PHASE2_F4C_SIGNED_GATE", environment)
        self.assertNotIn("MACSCOPE_RUN_PHASE2_F4C_INSTALLED_CANARY", environment)
        self.assertNotIn("LAUNCHER_MUST_NOT_INHERIT", environment)
        for key in ("HOME", "PATH", "TMPDIR", "USER"):
            self.assertIn(key, environment)
        self.assertEqual(self.stdout_log.read_text(), result.stdout)
        self.assertEqual(self.stderr_log.read_bytes(), b"")
        self.assertEqual(json.loads(result.stdout)["status"], "authority-verified")

    def test_canary_sets_only_canary_opt_in_and_invokes_candidate_once(self) -> None:
        self.write_candidate(
            """
            import json, os
            from pathlib import Path
            root = Path(__file__).resolve().parents[3]
            (root / "arguments.json").write_text(json.dumps(__import__("sys").argv[1:]))
            (root / "environment.json").write_text(json.dumps(dict(os.environ), sort_keys=True))
            record = {
                "app_executable_sha256": "a" * 64,
                "canary_evidence_sha256": "b" * 64,
                "evidence_location": (
                    "MacScope/Qualification/F4C/"
                    "01234567-89ab-cdef-0123-456789abcdef/canary.json"
                ),
                "git_head_commit": "c" * 40,
                "run_id": "01234567-89ab-cdef-0123-456789abcdef",
                "schema_version": 1,
                "status": "canary-completed",
                "worker_executable_sha256": "d" * 64,
            }
            print(json.dumps(record, separators=(",", ":"), sort_keys=True))
            """
        )

        result = self.run_launcher("--mode", "canary")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            json.loads((self.root / "arguments.json").read_text()),
            ["--phase2-f4c-installed-canary"],
        )
        environment = json.loads((self.root / "environment.json").read_text())
        self.assertEqual(
            environment["MACSCOPE_RUN_PHASE2_F4C_INSTALLED_CANARY"], "1"
        )
        self.assertNotIn("MACSCOPE_RUN_PHASE2_F4C_SIGNED_GATE", environment)
        self.assertEqual(json.loads(result.stdout)["status"], "canary-completed")

    def test_canary_rejects_incomplete_or_malformed_evidence_record(self) -> None:
        valid = {
            "app_executable_sha256": "a" * 64,
            "canary_evidence_sha256": "b" * 64,
            "evidence_location": (
                "MacScope/Qualification/F4C/"
                "01234567-89ab-cdef-0123-456789abcdef/canary.json"
            ),
            "git_head_commit": "c" * 40,
            "run_id": "01234567-89ab-cdef-0123-456789abcdef",
            "schema_version": 1,
            "status": "canary-completed",
            "worker_executable_sha256": "d" * 64,
        }
        invalid_records = []
        missing = dict(valid)
        del missing["worker_executable_sha256"]
        invalid_records.append(missing)
        malformed = dict(valid)
        malformed["canary_evidence_sha256"] = "b"
        invalid_records.append(malformed)
        mismatched_location = dict(valid)
        mismatched_location["evidence_location"] = "MacScope/Qualification/F4C/other.json"
        invalid_records.append(mismatched_location)

        for record in invalid_records:
            with self.subTest(record=record):
                terminal = (
                    json.dumps(record, separators=(",", ":"), sort_keys=True).encode()
                    + b"\n"
                )
                with self.assertRaises(run_signed_gate.LaunchError):
                    run_signed_gate.validate_terminal_record(terminal, b"", "canary")

    def test_canary_timeout_is_bounded_to_five_minutes(self) -> None:
        self.assertEqual(run_signed_gate.timeout_for("canary", None), 300.0)
        with self.assertRaisesRegex(run_signed_gate.LaunchError, "no more than 300"):
            run_signed_gate.timeout_for("canary", 300.1)

    def test_live_sets_exact_opt_in_and_invokes_candidate_once(self) -> None:
        self.write_candidate(
            """
            import json, os
            from pathlib import Path
            root = Path(__file__).resolve().parents[3]
            count_file = root / "count"
            count = int(count_file.read_text()) + 1 if count_file.exists() else 1
            count_file.write_text(str(count))
            (root / "environment.json").write_text(json.dumps(dict(os.environ), sort_keys=True))
            print('{"report_id":"r","schema_version":1,"status":"completed","verdict":"certified"}')
            """
        )

        result = self.run_launcher("--mode", "live")

        self.assertEqual(result.returncode, 0, result.stderr)
        environment = json.loads((self.root / "environment.json").read_text())
        self.assertEqual(environment["MACSCOPE_RUN_PHASE2_F4C_SIGNED_GATE"], "1")
        self.assertEqual((self.root / "count").read_text(), "1")
        self.assertEqual(json.loads(result.stdout)["status"], "completed")

    def test_rejects_multiple_noncanonical_or_wrong_status_records(self) -> None:
        cases = {
            "multiple": (
                "print('{\"schema_version\":1,\"status\":\"authority-verified\"}\\n"
                "{\"schema_version\":1,\"status\":\"authority-verified\"}')"
            ),
            "noncanonical": "print('{\"status\": \"authority-verified\", \"schema_version\": 1}')",
            "wrong-status": "print('{\"schema_version\":1,\"status\":\"completed\"}')",
        }
        for name, body in cases.items():
            with self.subTest(name=name):
                self.write_candidate(body)
                result = self.run_launcher()
                self.assertNotEqual(result.returncode, 0)
                self.assertTrue(self.stdout_log.exists())
                self.stdout_log.unlink()
                self.stderr_log.unlink()

    def test_rejects_candidate_stderr_even_with_valid_stdout(self) -> None:
        self.write_candidate(
            """
            import sys
            print('{"schema_version":1,"status":"authority-verified"}')
            print("unexpected diagnostic", file=sys.stderr)
            """
        )

        result = self.run_launcher()

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unexpected stderr", result.stderr)
        self.assertEqual(self.stderr_log.read_text(), "unexpected diagnostic\n")

    def test_timeout_terminates_and_reaps_only_recorded_candidate_pid(self) -> None:
        self.write_sleeping_native_candidate()

        result = self.run_launcher("--timeout-seconds", "0.2")

        self.assertNotEqual(result.returncode, 0)
        pid = int((self.root / "pid").read_text())
        with self.assertRaises(ProcessLookupError):
            os.kill(pid, 0)
        self.assertIn("timed out", result.stderr)

    def test_timeout_does_not_signal_unbound_same_candidate_worker_and_fails_closed(self) -> None:
        worker = self.write_sleeping_worker()
        self.write_sleeping_native_candidate()
        same_candidate_worker = subprocess.Popen([str(worker), "60"])
        unrelated = subprocess.Popen(["/bin/sleep", "60"])
        try:
            result = self.run_launcher("--timeout-seconds", "0.2")

            self.assertNotEqual(result.returncode, 0)
            self.assertIsNone(same_candidate_worker.poll())
            self.assertIn(
                same_candidate_worker.pid,
                run_signed_gate.pids_for_exact_executable(worker.resolve(strict=True)),
            )
            self.assertIsNone(unrelated.poll())
            self.assertIn("refusing to signal unbound exact-path PID(s)", result.stderr)
        finally:
            for process in (same_candidate_worker, unrelated):
                if process.poll() is None:
                    process.terminate()
                process.wait(timeout=2.0)

    def test_signal_revalidates_executable_immediately_before_signaling(self) -> None:
        expected = self.root / "expected"
        replacement = self.root / "replacement"
        with (
            mock.patch.object(
                run_signed_gate,
                "canonical_executable_for_pid",
                side_effect=[expected, replacement],
            ),
            mock.patch.object(run_signed_gate.os, "kill") as kill,
        ):
            self.assertTrue(run_signed_gate.pid_matches_executable(4123, expected))
            self.assertFalse(
                run_signed_gate.signal_if_owned(4123, expected, signal.SIGTERM)
            )
        kill.assert_not_called()

    def test_candidate_worker_confirmation_succeeds_when_none_remain(self) -> None:
        worker = self.write_sleeping_worker()
        run_signed_gate.confirm_candidate_workers_gone(
            worker.resolve(strict=True),
            grace_seconds=0.1,
        )

    def test_candidate_worker_confirmation_fails_without_signaling_residual_worker(self) -> None:
        worker = self.write_sleeping_worker()
        worker_process = subprocess.Popen([str(worker), "60"])
        try:
            with mock.patch.object(run_signed_gate.os, "kill") as kill:
                with self.assertRaisesRegex(
                    run_signed_gate.LaunchError,
                    "refusing to signal unbound exact-path PID",
                ):
                    run_signed_gate.confirm_candidate_workers_gone(
                        worker.resolve(strict=True),
                        grace_seconds=0.1,
                    )
            kill.assert_not_called()
            self.assertIsNone(worker_process.poll())
        finally:
            if worker_process.poll() is None:
                worker_process.terminate()
            worker_process.wait(timeout=2.0)

    def test_requires_absolute_candidate_app_and_fresh_distinct_log_paths(self) -> None:
        self.write_candidate("print('{\"schema_version\":1,\"status\":\"authority-verified\"}')")
        relative = subprocess.run(
            [
                sys.executable,
                str(SCRIPT),
                "--candidate-app",
                "MacScope.app",
                "--stdout-log",
                str(self.stdout_log),
                "--stderr-log",
                str(self.stderr_log),
            ],
            text=True,
            capture_output=True,
            check=False,
        )
        self.assertNotEqual(relative.returncode, 0)

        self.stdout_log.write_text("existing evidence")
        existing = self.run_launcher()
        self.assertNotEqual(existing.returncode, 0)
        self.assertEqual(self.stdout_log.read_text(), "existing evidence")

    def write_candidate(self, body: str) -> None:
        source = "#!/usr/bin/python3\n" + textwrap.dedent(body).strip() + "\n"
        self.executable.write_text(source)
        self.executable.chmod(0o755)

    def write_sleeping_native_candidate(self, worker: Path | None = None) -> None:
        source = self.root / "candidate.c"
        spawn_worker = ""
        if worker is not None:
            spawn_worker = textwrap.dedent(
                f"""
                pid_t worker_pid = fork();
                if (worker_pid == 0) {{
                    execl("{worker}", "{worker.name}", "60", NULL);
                    _exit(127);
                }}
                FILE *worker_pid_file = fopen("{self.root / 'worker-pid'}", "w");
                if (worker_pid_file == NULL) return 3;
                fprintf(worker_pid_file, "%d", worker_pid);
                fclose(worker_pid_file);
                """
            )
        source.write_text(
            textwrap.dedent(
                f"""
                #include <stdio.h>
                #include <stdlib.h>
                #include <unistd.h>

                int main(void) {{
                    FILE *pid_file = fopen("{self.root / 'pid'}", "w");
                    if (pid_file == NULL) return 2;
                    fprintf(pid_file, "%d", getpid());
                    fclose(pid_file);
                    {spawn_worker}
                    sleep(60);
                    return 0;
                }}
                """
            )
        )
        subprocess.run(
            ["/usr/bin/clang", str(source), "-o", str(self.executable)],
            check=True,
            capture_output=True,
        )

    def write_sleeping_worker(self) -> Path:
        worker = (
            self.app
            / "Contents"
            / "XPCServices"
            / "AIAgentWorkerXPCService.xpc"
            / "Contents"
            / "MacOS"
            / "AIAgentWorkerXPCService"
        )
        worker.parent.mkdir(parents=True, exist_ok=True)
        source = self.root / "worker.c"
        source.write_text(
            textwrap.dedent(
                """
                #include <stdlib.h>
                #include <unistd.h>

                int main(int argc, char **argv) {
                    unsigned int duration = argc > 1 ? (unsigned int)atoi(argv[1]) : 60;
                    sleep(duration);
                    return 0;
                }
                """
            )
        )
        subprocess.run(
            ["/usr/bin/clang", str(source), "-o", str(worker)],
            check=True,
            capture_output=True,
        )
        return worker

    def run_launcher(self, *extra: str) -> subprocess.CompletedProcess[str]:
        launcher_environment = dict(os.environ)
        launcher_environment["LAUNCHER_MUST_NOT_INHERIT"] = "secret"
        return subprocess.run(
            [
                sys.executable,
                str(SCRIPT),
                "--candidate-app",
                str(self.app),
                "--stdout-log",
                str(self.stdout_log),
                "--stderr-log",
                str(self.stderr_log),
                *extra,
            ],
            text=True,
            capture_output=True,
            check=False,
            env=launcher_environment,
        )


if __name__ == "__main__":
    unittest.main()
