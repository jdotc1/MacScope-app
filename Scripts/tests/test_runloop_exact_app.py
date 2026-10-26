from __future__ import annotations

import importlib.util
import io
import json
import os
import plistlib
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import textwrap
import unittest
from dataclasses import dataclass
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[2]
MODULE_PATH = ROOT / "Scripts/runloop_exact_app.py"
SPEC = importlib.util.spec_from_file_location("macscope_runloop_exact_app", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
runloop = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = runloop
SPEC.loader.exec_module(runloop)


@dataclass(frozen=True)
class FakeBSDInfo:
    pid: int
    start_seconds: int
    start_microseconds: int


class FakeProcessAPI:
    def __init__(
        self,
        *,
        pid: int = 42,
        start_seconds: int = 100,
        start_microseconds: int = 200,
        path: str = "/private/tmp/MacScope.app/Contents/MacOS/MacScope",
        reuse_after_reads: int | None = None,
    ) -> None:
        self.pid = pid
        self.start_seconds = start_seconds
        self.start_microseconds = start_microseconds
        self.path = path
        self.alive = True
        self.read_count = 0
        self.reuse_after_reads = reuse_after_reads

    def bsd_info(self, pid: int) -> FakeBSDInfo:
        self.read_count += 1
        if not self.alive or pid != self.pid:
            raise ProcessLookupError(pid)
        start_seconds = self.start_seconds
        if self.reuse_after_reads is not None and self.read_count >= self.reuse_after_reads:
            start_seconds += 1
        return FakeBSDInfo(pid, start_seconds, self.start_microseconds)

    def pid_path(self, pid: int) -> str:
        if not self.alive or pid != self.pid:
            raise ProcessLookupError(pid)
        return self.path


def process_receipt(api: FakeProcessAPI, generation: str = "generation-1") -> dict[str, object]:
    return {
        "schema": runloop.PROCESS_SCHEMA,
        "buildGeneration": generation,
        "launchedAtUnixNs": 1,
        "pid": api.pid,
        "startSeconds": api.start_seconds,
        "startMicroseconds": api.start_microseconds,
        "executablePath": api.path,
        "finishedLaunching": True,
        "activationPolicy": 0,
        "firstWindowReady": True,
    }


class FakeDiagnosticChild:
    def __init__(self, payload: bytes = b"") -> None:
        read_descriptor, write_descriptor = os.pipe()
        self.stdout = os.fdopen(read_descriptor, "rb", buffering=0)
        self.write_descriptor = write_descriptor
        self.returncode: int | None = None
        self.terminated = False
        self.killed = False
        if payload:
            os.write(self.write_descriptor, payload)

    def poll(self) -> int | None:
        return self.returncode

    def terminate(self) -> None:
        self.terminated = True
        self.returncode = -signal.SIGTERM
        if self.write_descriptor >= 0:
            os.close(self.write_descriptor)
            self.write_descriptor = -1

    def wait(self, timeout: float | None = None) -> int:
        del timeout
        if self.returncode is None:
            raise subprocess.TimeoutExpired("fake-log", 0)
        return self.returncode

    def kill(self) -> None:
        self.killed = True
        self.returncode = -signal.SIGKILL
        if self.write_descriptor >= 0:
            os.close(self.write_descriptor)
            self.write_descriptor = -1


class FakeLaunchHandoff:
    def __init__(self, pid: int, executable_path: str) -> None:
        self.identity: dict[str, object] = {
            "pid": pid,
            "executablePath": executable_path,
        }
        self.ack_sent = False
        self.acknowledged = False
        self.aborted = False

    def acknowledge(self) -> None:
        self.ack_sent = True
        self.acknowledged = True

    def abort(self) -> None:
        self.aborted = True


class InterruptingSelector:
    def __init__(self) -> None:
        self.selector = runloop.selectors.DefaultSelector()

    def register(self, *arguments: object) -> object:
        return self.selector.register(*arguments)

    def select(self, timeout: float | None = None) -> object:
        del timeout
        raise KeyboardInterrupt()

    def close(self) -> None:
        self.selector.close()


class RunLoopExactAppTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary_directory.cleanup)
        self.root = Path(self.temporary_directory.name)

    def launch_build(self, api: FakeProcessAPI) -> dict[str, object]:
        return {
            "buildGeneration": "generation-1",
            "appBundlePath": "/private/tmp/MacScope.app",
            "executablePath": api.path,
            "repositoryRoot": str(self.root),
        }

    def make_handoff_fixture(
        self,
        *,
        output_mode: str = "identity",
        cleanup_proved: bool = True,
        expected_process_receipt: Path | None = None,
    ) -> runloop.CompiledLaunchHelper:
        helper = self.root / f"handoff-{output_mode}-{cleanup_proved}.py"
        source = textwrap.dedent(
            f"""\
            #!/usr/bin/python3
            import json
            import os
            from pathlib import Path
            import select
            import sys

            OUTPUT_MODE = {output_mode!r}
            CLEANUP_PROVED = {cleanup_proved!r}
            EXPECTED_PROCESS_RECEIPT = {str(expected_process_receipt) if expected_process_receipt else None!r}
            ACK_TIMEOUT = float(sys.argv[3])
            PID = 42
            EXECUTABLE = "/private/tmp/MacScope.app/Contents/MacOS/MacScope"
            APP_BUNDLE = os.path.realpath(sys.argv[1])
            RECOVERY = Path(sys.argv[2])
            LAUNCH_NONCE = sys.argv[4]

            def write_recovery(state, proved):
                value = {{
                    "appBundlePath": APP_BUNDLE,
                    "cleanupProved": proved,
                    "executablePath": EXECUTABLE,
                    "handoffState": state,
                    "helperPID": os.getpid(),
                    "launchNonce": LAUNCH_NONCE,
                    "pid": PID,
                    "schema": "macscope.developer-run-handoff.v1",
                }}
                # Publish atomically, as the compiled helper does, so the parent
                # never reads a truncated receipt mid-write.
                temporary = RECOVERY.with_name(f".{{RECOVERY.name}}.{{os.getpid()}}.tmp")
                temporary.write_text(
                    json.dumps(value, sort_keys=True, separators=(",", ":")) + "\\n",
                    encoding="utf-8",
                )
                temporary.chmod(0o600)
                os.replace(temporary, RECOVERY)

            write_recovery("helper-owned", False)
            if OUTPUT_MODE == "identity":
                value = {{"executablePath": EXECUTABLE, "pid": PID}}
                os.write(
                    1,
                    (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\\n").encode(),
                )
            elif OUTPUT_MODE == "partial":
                os.write(1, b'{{"pid":42')

            readable, _, _ = select.select([0], [], [], ACK_TIMEOUT)
            acknowledgement = os.read(0, 16) if readable else b""
            if acknowledgement == b"ACK\\n":
                if EXPECTED_PROCESS_RECEIPT is not None:
                    provisional_path = Path(EXPECTED_PROCESS_RECEIPT)
                    provisional = json.loads(provisional_path.read_text(encoding="utf-8"))
                    if (
                        provisional_path.stat().st_mode & 0o777 != 0o600
                        or provisional.get("schema") != "macscope.developer-run-process.v1"
                        or provisional.get("pid") != PID
                        or provisional.get("firstWindowReady") is not False
                    ):
                        raise SystemExit(22)
                write_recovery("python-owned", False)
                raise SystemExit(0)
            if CLEANUP_PROVED:
                write_recovery("terminated", True)
                raise SystemExit(20)
            write_recovery("cleanup-failed", False)
            raise SystemExit(21)
            """
        )
        helper.write_text(source, encoding="utf-8")
        helper.chmod(0o700)
        return runloop.CompiledLaunchHelper(
            helper,
            runloop._stable_ordinary_file_identity(
                helper,
                label="fixture launch helper",
                require_mode=0o700,
                require_executable=True,
            )["sha256"],
            "fixture",
        )

    def make_preidentity_handoff_fixture(
        self,
        mode: str,
        *,
        delay_seconds: float = 0.25,
    ) -> runloop.CompiledLaunchHelper:
        helper = self.root / f"preidentity-{mode}.py"
        source = textwrap.dedent(
            f"""\
            #!/usr/bin/python3
            import json
            import os
            from pathlib import Path
            import sys
            import time

            MODE = {mode!r}
            DELAY_SECONDS = {delay_seconds!r}
            APP_BUNDLE = os.path.realpath(sys.argv[1])
            RECOVERY = Path(sys.argv[2])
            LAUNCH_NONCE = sys.argv[4]

            def write_recovery(state, proved):
                value = {{
                    "appBundlePath": APP_BUNDLE,
                    "cleanupProved": proved,
                    "handoffState": state,
                    "helperPID": os.getpid(),
                    "launchNonce": LAUNCH_NONCE,
                    "schema": "macscope.developer-run-handoff.v1",
                }}
                # Publish atomically, as the compiled helper does, so the parent
                # never reads a truncated receipt mid-write.
                temporary = RECOVERY.with_name(f".{{RECOVERY.name}}.{{os.getpid()}}.tmp")
                temporary.write_text(
                    json.dumps(value, sort_keys=True, separators=(",", ":")) + "\\n",
                    encoding="utf-8",
                )
                temporary.chmod(0o600)
                os.replace(temporary, RECOVERY)

            if MODE == "delayed-no-application":
                write_recovery("opening", False)
                time.sleep(DELAY_SECONDS)
                write_recovery("no-application", True)
                raise SystemExit(20)
            if MODE == "partial-without-helper-recovery":
                os.write(1, b'{{"pid":')
                os.read(0, 16)
                raise SystemExit(21)
            if MODE == "no-output-without-helper-recovery":
                os.read(0, 16)
                raise SystemExit(21)
            if MODE == "cleanup-failed":
                write_recovery("opening", False)
                os.write(1, b'{{"pid":')
                os.read(0, 16)
                write_recovery("cleanup-failed", False)
                raise SystemExit(21)
            raise SystemExit(2)
            """
        )
        helper.write_text(source, encoding="utf-8")
        helper.chmod(0o700)
        return runloop.CompiledLaunchHelper(
            helper,
            runloop._stable_ordinary_file_identity(
                helper,
                label="preidentity fixture launch helper",
                require_mode=0o700,
                require_executable=True,
            )["sha256"],
            "preidentity-fixture",
        )

    def fixture_handoff_factory(
        self,
        helper: runloop.CompiledLaunchHelper,
        **options: object,
    ) -> object:
        def factory(
            app_bundle: Path,
            process_receipt: Path,
            repository: Path,
        ) -> runloop.LaunchHandoff:
            return runloop.begin_launch_handoff(
                app_bundle,
                process_receipt,
                repository,
                compiled_helper=helper,
                identity_timeout_seconds=float(options.get("identity_timeout", 1.0)),
                ack_timeout_seconds=float(options.get("ack_timeout", 1.0)),
                exit_timeout_seconds=float(options.get("exit_timeout", 2.0)),
                selector_factory=options.get(
                    "selector_factory", runloop.selectors.DefaultSelector
                ),
            )

        return factory

    def make_build_fixture(
        self,
    ) -> tuple[Path, Path, Path, Path, dict[str, object], dict[str, object]]:
        repository = self.root / "repository"
        owner = repository / "Scripts/qualification/restore_build_source.py"
        owner.parent.mkdir(parents=True)
        shutil.copy2(ROOT / "Scripts/qualification/restore_build_source.py", owner)
        project = repository / "MacScope/MacScope.xcodeproj"
        generated_files = {
            ".macscope-project-generation.sha256": "generation\n",
            "project.xcproj": "// project\n",
            "project.xcworkspace/contents.xcworkspacedata": "<Workspace/>\n",
            "xcshareddata/xcschemes/MacScopeApp.xcscheme": "<Scheme/>\n",
            "xcshareddata/xcschemes/CoreTests.xcscheme": "<Scheme/>\n",
            "xcshareddata/xcschemes/Phase2Tests.xcscheme": "<Scheme/>\n",
            "xcshareddata/xcschemes/MacScopeInstalledAppUITests.xcscheme": "<Scheme/>\n",
        }
        for relative, value in generated_files.items():
            candidate = project / relative
            candidate.parent.mkdir(parents=True, exist_ok=True)
            candidate.write_text(value, encoding="utf-8")

        app_bundle = self.root / "products/MacScope.app"
        executable = app_bundle / "Contents/MacOS/MacScope"
        executable.parent.mkdir(parents=True)
        executable.write_bytes(b"fixture executable")
        with (app_bundle / "Contents/Info.plist").open("wb") as handle:
            plistlib.dump(
                {
                    "CFBundleIdentifier": runloop.EXPECTED_BUNDLE_IDENTIFIER,
                    "CFBundleExecutable": runloop.EXPECTED_EXECUTABLE_NAME,
                },
                handle,
            )
        source = {
            "repositoryRoot": str(repository.resolve()),
            "identitySha256": "a" * 64,
        }
        dependency_contract: dict[str, object] = {
            "configSha256": "b" * 64,
            "roots": {"MACSCOPE_GHOSTTY_SURFACE_WORK_ROOT": "/verified/ghostty"},
            "receipts": {"/verified/ghostty/receipt": "c" * 64},
            "identitySha256": "d" * 64,
        }
        return (
            repository,
            project,
            app_bundle,
            executable,
            source,
            dependency_contract,
        )

    def test_atomic_receipt_is_canonical_mode_0600_and_round_trips(self) -> None:
        receipt = self.root / "receipts/process-receipt.json"
        value = {
            "schema": runloop.PROCESS_SCHEMA,
            "z": 2,
            "a": 1,
        }
        runloop.atomic_write_receipt(receipt, value)

        self.assertEqual(stat.S_IMODE(receipt.stat().st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(receipt.parent.stat().st_mode), 0o700)
        self.assertEqual(
            receipt.read_bytes(),
            b'{"a":1,"schema":"macscope.developer-run-process.v1","z":2}\n',
        )
        self.assertEqual(runloop.load_receipt(receipt, runloop.PROCESS_SCHEMA), value)

    def test_receipt_rejects_broad_permissions_and_symbolic_links(self) -> None:
        receipt = self.root / "receipt.json"
        runloop.atomic_write_receipt(
            receipt, {"schema": runloop.PROCESS_SCHEMA, "value": 1}
        )
        receipt.chmod(0o644)
        with self.assertRaisesRegex(runloop.RunLoopError, "mode-0600"):
            runloop.load_receipt(receipt, runloop.PROCESS_SCHEMA)

        receipt.chmod(0o600)
        link = self.root / "receipt-link.json"
        link.symlink_to(receipt)
        with self.assertRaises(runloop.RunLoopError):
            runloop.load_receipt(link, runloop.PROCESS_SCHEMA)

        real_directory = self.root / "real-receipts"
        real_directory.mkdir()
        linked_directory = self.root / "linked-receipts"
        linked_directory.symlink_to(real_directory, target_is_directory=True)
        with self.assertRaisesRegex(runloop.RunLoopError, "receipt directory"):
            runloop.atomic_write_receipt(
                linked_directory / "new.json", {"schema": runloop.PROCESS_SCHEMA}
            )

    def test_capture_uses_pid_start_and_path_a_b_a_identity(self) -> None:
        api = FakeProcessAPI()
        observed = runloop.capture_exact_process(api, api.pid)

        self.assertEqual(
            observed,
            runloop.ExactProcess(api.pid, 100, 200, api.path),
        )
        self.assertEqual(api.read_count, 2)

    def test_capture_rejects_start_generation_race(self) -> None:
        api = FakeProcessAPI()

        def racing_bsd_info(pid: int) -> FakeBSDInfo:
            api.read_count += 1
            return FakeBSDInfo(pid, 100 + api.read_count, 200)

        api.bsd_info = racing_bsd_info  # type: ignore[method-assign]
        with self.assertRaisesRegex(runloop.RunLoopError, "A-B-A"):
            runloop.capture_exact_process(api, api.pid)

    def test_repository_darwin_api_captures_this_exact_process(self) -> None:
        if os.uname().sysname != "Darwin":
            self.skipTest("Darwin libproc is macOS-only")
        observed = runloop.capture_exact_process(runloop._default_process_api(), os.getpid())
        self.assertEqual(observed.pid, os.getpid())
        self.assertTrue(observed.executable_path.startswith("/"))

    def test_stop_signals_only_exact_receipted_process_and_removes_receipt(self) -> None:
        api = FakeProcessAPI()
        receipt_path = self.root / "process.json"
        runloop.atomic_write_receipt(receipt_path, process_receipt(api))
        signals: list[tuple[int, int]] = []

        def signal_process(pid: int, signal_number: int) -> None:
            signals.append((pid, signal_number))
            api.alive = False

        stopped = runloop.retire_receipted_process(
            receipt_path,
            process_api=api,
            signal_process=signal_process,
            sleeper=lambda _: None,
            monotonic=iter((0.0, 0.1)).__next__,
        )

        self.assertTrue(stopped)
        self.assertEqual(signals, [(api.pid, signal.SIGTERM)])
        self.assertFalse(receipt_path.exists())

    def test_stop_refuses_pid_reuse_without_signalling(self) -> None:
        api = FakeProcessAPI(start_seconds=101)
        receipt_path = self.root / "process.json"
        stale = process_receipt(api)
        stale["startSeconds"] = 100
        runloop.atomic_write_receipt(receipt_path, stale)
        signals: list[tuple[int, int]] = []

        with self.assertRaisesRegex(runloop.RunLoopError, "refusing to signal"):
            runloop.retire_receipted_process(
                receipt_path,
                process_api=api,
                signal_process=lambda pid, number: signals.append((pid, number)),
            )

        self.assertEqual(signals, [])
        self.assertTrue(receipt_path.exists())

    def test_gone_receipted_process_is_cleaned_without_signalling(self) -> None:
        api = FakeProcessAPI()
        receipt_path = self.root / "process.json"
        runloop.atomic_write_receipt(receipt_path, process_receipt(api))
        api.alive = False
        signals: list[tuple[int, int]] = []

        stopped = runloop.retire_receipted_process(
            receipt_path,
            process_api=api,
            signal_process=lambda pid, number: signals.append((pid, number)),
        )

        self.assertFalse(stopped)
        self.assertEqual(signals, [])
        self.assertFalse(receipt_path.exists())

    def test_launch_owns_nsworkspace_pid_and_ignores_concurrent_manual_launch(self) -> None:
        api = FakeProcessAPI()
        build_path = self.root / "build.json"
        process_path = self.root / "process.json"
        build = self.launch_build(api)
        inventories = iter(
            (
                [
                    {
                        "pid": 9,
                        "executablePath": api.path,
                        "finishedLaunching": True,
                        "activationPolicy": 0,
                    }
                ],
                [
                    {
                        "pid": api.pid,
                        "executablePath": api.path,
                        "finishedLaunching": True,
                        "activationPolicy": 0,
                    }
                ],
            )
        )
        launches: list[Path] = []

        handoff = FakeLaunchHandoff(api.pid, api.path)

        def make_handoff(
            bundle: Path, _receipt: Path, _repository: Path
        ) -> FakeLaunchHandoff:
            launches.append(bundle)
            return handoff

        with mock.patch.object(runloop, "validate_build_receipt", return_value=build):
            receipt = runloop.launch_exact_process(
                build_path,
                process_path,
                process_api=api,
                application_inventory=lambda: next(inventories),
                count_windows=lambda pid: 1,
                handoff_factory=make_handoff,
                sleeper=lambda _: None,
                monotonic=iter((0.0, 0.1, 0.2)).__next__,
            )

        self.assertEqual(launches, [Path("/private/tmp/MacScope.app")])
        self.assertEqual(receipt["pid"], api.pid)
        self.assertTrue(handoff.acknowledged)
        self.assertTrue(receipt["firstWindowReady"])
        self.assertEqual(stat.S_IMODE(process_path.stat().st_mode), 0o600)
        self.assertEqual(
            runloop.load_receipt(process_path, runloop.PROCESS_SCHEMA), receipt
        )

    def test_launch_exact_cleans_owned_process_on_identity_failure(self) -> None:
        api = FakeProcessAPI()
        process_path = self.root / "process.json"
        build = self.launch_build(api)
        signals: list[tuple[int, int]] = []
        handoff = FakeLaunchHandoff(
            api.pid, "/private/tmp/Other.app/Contents/MacOS/Other"
        )

        def signal_process(pid: int, number: int) -> None:
            signals.append((pid, number))
            api.alive = False

        with mock.patch.object(runloop, "validate_build_receipt", return_value=build):
            with self.assertRaisesRegex(runloop.RunLoopError, "disagree"):
                runloop.launch_exact_process(
                    self.root / "build.json",
                    process_path,
                    process_api=api,
                    handoff_factory=lambda *_: handoff,
                    signal_process=signal_process,
                    monotonic=lambda: 0.0,
                    stop_sleeper=lambda _: None,
                    stop_monotonic=iter((0.0, 0.1)).__next__,
                )

        self.assertEqual(signals, [])
        self.assertTrue(handoff.aborted)
        self.assertFalse(process_path.exists())

    def test_launch_exact_cleans_owned_process_on_receipt_failure(self) -> None:
        api = FakeProcessAPI()
        process_path = self.root / "process.json"
        build = self.launch_build(api)
        signals: list[tuple[int, int]] = []
        handoff = FakeLaunchHandoff(api.pid, api.path)

        def signal_process(pid: int, number: int) -> None:
            signals.append((pid, number))
            api.alive = False

        with (
            mock.patch.object(runloop, "validate_build_receipt", return_value=build),
            mock.patch.object(runloop, "atomic_write_receipt", side_effect=OSError("full")),
        ):
            with self.assertRaisesRegex(runloop.RunLoopError, "receipt/readiness"):
                runloop.launch_exact_process(
                    self.root / "build.json",
                    process_path,
                    process_api=api,
                    handoff_factory=lambda *_: handoff,
                    signal_process=signal_process,
                    monotonic=lambda: 0.0,
                    stop_sleeper=lambda _: None,
                    stop_monotonic=iter((0.0, 0.1)).__next__,
                )

        self.assertEqual(signals, [])
        self.assertTrue(handoff.aborted)
        self.assertFalse(process_path.exists())

    def test_launch_exact_cleans_owned_process_on_readiness_timeout(self) -> None:
        api = FakeProcessAPI()
        process_path = self.root / "process.json"
        build = self.launch_build(api)
        signals: list[tuple[int, int]] = []
        handoff = FakeLaunchHandoff(api.pid, api.path)

        def signal_process(pid: int, number: int) -> None:
            signals.append((pid, number))
            api.alive = False

        with mock.patch.object(runloop, "validate_build_receipt", return_value=build):
            with self.assertRaisesRegex(runloop.RunLoopError, "first-window readiness"):
                runloop.launch_exact_process(
                    self.root / "build.json",
                    process_path,
                    process_api=api,
                    application_inventory=lambda: [],
                    handoff_factory=lambda *_: handoff,
                    signal_process=signal_process,
                    sleeper=lambda _: None,
                    monotonic=iter((0.0, 100.0)).__next__,
                    stop_sleeper=lambda _: None,
                    stop_monotonic=iter((0.0, 0.1)).__next__,
                )

        self.assertEqual(signals, [(api.pid, signal.SIGTERM)])
        self.assertTrue(handoff.acknowledged)
        self.assertFalse(process_path.exists())

    def test_launch_exact_cleans_owned_process_when_readiness_is_interrupted(self) -> None:
        api = FakeProcessAPI()
        process_path = self.root / "process.json"
        build = self.launch_build(api)
        signals: list[tuple[int, int]] = []
        handoff = FakeLaunchHandoff(api.pid, api.path)

        def signal_process(pid: int, number: int) -> None:
            signals.append((pid, number))
            api.alive = False

        with mock.patch.object(runloop, "validate_build_receipt", return_value=build):
            with self.assertRaises(KeyboardInterrupt):
                runloop.launch_exact_process(
                    self.root / "build.json",
                    process_path,
                    process_api=api,
                    application_inventory=lambda: (_ for _ in ()).throw(
                        KeyboardInterrupt()
                    ),
                    handoff_factory=lambda *_: handoff,
                    signal_process=signal_process,
                    sleeper=lambda _: None,
                    monotonic=iter((0.0, 0.1)).__next__,
                    stop_sleeper=lambda _: None,
                    stop_monotonic=iter((0.0, 0.1)).__next__,
                )

        self.assertEqual(signals, [(api.pid, signal.SIGTERM)])
        self.assertTrue(handoff.acknowledged)
        self.assertFalse(process_path.exists())

    def test_compiled_helper_cache_reuses_only_exact_source_and_toolchain_key(self) -> None:
        repository = self.root / "cache-repository"
        repository.mkdir()
        cache = self.root / "external-cache"
        swiftc = self.root / "fixture-swiftc"
        swiftc.write_bytes(b"fixture swift compiler")
        swiftc.chmod(0o700)
        compile_inputs: list[bytes] = []

        def toolchain(label: str) -> dict[str, object]:
            core: dict[str, object] = {
                "developerDirectory": f"/Applications/{label}.app/Contents/Developer",
                "xcodeVersion": label,
                "swiftcVersion": label,
                "swiftc": {"path": str(swiftc), "sha256": "e" * 64},
            }
            return {
                **core,
                "identitySha256": runloop._sha256_bytes(runloop._canonical_json(core)),
            }

        def compile_helper(_swiftc: Path, source: Path, output: Path) -> None:
            payload = source.read_bytes()
            compile_inputs.append(payload)
            output.write_bytes(b"compiled:" + payload)

        first = runloop.ensure_compiled_launch_helper(
            repository,
            cache_root=cache,
            source_bytes=b"source-a",
            toolchain_identity_provider=lambda: toolchain("Xcode-A"),
            compiler=compile_helper,
        )
        reused = runloop.ensure_compiled_launch_helper(
            repository,
            cache_root=cache,
            source_bytes=b"source-a",
            toolchain_identity_provider=lambda: toolchain("Xcode-A"),
            compiler=compile_helper,
        )
        changed_source = runloop.ensure_compiled_launch_helper(
            repository,
            cache_root=cache,
            source_bytes=b"source-b",
            toolchain_identity_provider=lambda: toolchain("Xcode-A"),
            compiler=compile_helper,
        )
        changed_toolchain = runloop.ensure_compiled_launch_helper(
            repository,
            cache_root=cache,
            source_bytes=b"source-a",
            toolchain_identity_provider=lambda: toolchain("Xcode-B"),
            compiler=compile_helper,
        )

        self.assertEqual(first, reused)
        self.assertNotEqual(first.cache_key, changed_source.cache_key)
        self.assertNotEqual(first.cache_key, changed_toolchain.cache_key)
        self.assertEqual(compile_inputs, [b"source-a", b"source-b", b"source-a"])
        self.assertNotIn(repository, first.path.parents)
        self.assertEqual(stat.S_IMODE(first.path.stat().st_mode), 0o700)

    def test_selected_swiftc_symlink_binds_resolved_compiler_bytes(self) -> None:
        target = self.root / "swift-frontend"
        target.write_bytes(b"compiler bytes")
        target.chmod(0o700)
        selected = self.root / "swiftc"
        selected.symlink_to(target.name)

        identity = runloop._selected_command_identity(
            selected,
            label="selected swiftc",
        )

        self.assertEqual(identity["path"], str(selected))
        self.assertEqual(identity["linkTarget"], target.name)
        self.assertEqual(identity["resolved"]["path"], str(target.resolve()))
        self.assertEqual(
            identity["resolved"]["sha256"],
            runloop._sha256_bytes(b"compiler bytes"),
        )

    def test_toolchain_identity_uses_xcrun_effective_developer_directory(self) -> None:
        developer = self.root / "EffectiveXcode.app/Contents/Developer"
        xcodebuild = developer / "usr/bin/xcodebuild"
        swift_frontend = (
            developer
            / "Toolchains/XcodeDefault.xctoolchain/usr/bin/swift-frontend"
        )
        swiftc = swift_frontend.with_name("swiftc")
        xcodebuild.parent.mkdir(parents=True)
        swift_frontend.parent.mkdir(parents=True)
        xcodebuild.write_bytes(b"xcodebuild")
        xcodebuild.chmod(0o700)
        swift_frontend.write_bytes(b"swift frontend")
        swift_frontend.chmod(0o700)
        swiftc.symlink_to(swift_frontend.name)
        calls: list[tuple[str, ...]] = []

        def run_command(
            argv: object,
            *,
            cwd: Path | None = None,
            timeout: float = 120.0,
        ) -> subprocess.CompletedProcess[bytes]:
            del cwd, timeout
            command = tuple(argv)  # type: ignore[arg-type]
            calls.append(command)
            if command == ("/usr/bin/xcrun", "--find", "xcodebuild"):
                output = f"{xcodebuild}\n".encode()
            elif command == ("/usr/bin/xcrun", "--find", "swiftc"):
                output = f"{swiftc}\n".encode()
            elif command == (str(xcodebuild), "-version"):
                output = b"Xcode Effective\n"
            elif command == (str(swiftc), "--version"):
                output = b"Swift Effective\n"
            else:
                raise AssertionError(command)
            return subprocess.CompletedProcess(command, 0, output, b"")

        with (
            mock.patch.object(runloop, "_run", side_effect=run_command),
            mock.patch.dict(
                os.environ,
                {"DEVELOPER_DIR": str(developer)},
                clear=False,
            ),
        ):
            identity = runloop.swift_toolchain_identity()

        self.assertEqual(identity["developerDirectory"], str(developer.resolve()))
        self.assertEqual(identity["xcodebuild"]["path"], str(xcodebuild))
        self.assertEqual(identity["swiftc"]["path"], str(swiftc))
        self.assertFalse(any("xcode-select" in command for command in calls))

        outside_swiftc = self.root / "OtherToolchain/usr/bin/swiftc"
        outside_swiftc.parent.mkdir(parents=True)
        outside_swiftc.write_bytes(b"outside compiler")
        outside_swiftc.chmod(0o700)

        def mixed_run(
            argv: object,
            *,
            cwd: Path | None = None,
            timeout: float = 120.0,
        ) -> subprocess.CompletedProcess[bytes]:
            del cwd, timeout
            command = tuple(argv)  # type: ignore[arg-type]
            if command == ("/usr/bin/xcrun", "--find", "xcodebuild"):
                output = f"{xcodebuild}\n".encode()
            elif command == ("/usr/bin/xcrun", "--find", "swiftc"):
                output = f"{outside_swiftc}\n".encode()
            else:
                raise AssertionError(command)
            return subprocess.CompletedProcess(command, 0, output, b"")

        with mock.patch.object(runloop, "_run", side_effect=mixed_run):
            with self.assertRaisesRegex(runloop.RunLoopError, "effective Xcode default"):
                runloop.swift_toolchain_identity()

    def test_compile_refuses_inflight_toolchain_mutation_before_publish(self) -> None:
        repository = self.root / "cache-repository"
        repository.mkdir()
        cache = self.root / "external-cache"
        compiler_target = self.root / "swift-frontend"
        compiler_target.write_bytes(b"compiler-before")
        compiler_target.chmod(0o700)
        swiftc = self.root / "swiftc"
        swiftc.symlink_to(compiler_target.name)
        events: list[str] = []

        def toolchain() -> dict[str, object]:
            events.append("identity")
            core: dict[str, object] = {
                "developerDirectory": "/Applications/Fixture.app/Contents/Developer",
                "xcodeVersion": "Fixture Xcode",
                "swiftcVersion": "Fixture Swift",
                "swiftc": runloop._selected_command_identity(
                    swiftc,
                    label="fixture swiftc",
                ),
            }
            return {
                **core,
                "identitySha256": runloop._sha256_bytes(runloop._canonical_json(core)),
            }

        def mutate_during_compile(
            _swiftc: Path,
            source: Path,
            output: Path,
        ) -> None:
            events.append("compile")
            output.write_bytes(b"compiled:" + source.read_bytes())
            compiler_target.write_bytes(b"compiler-after")
            compiler_target.chmod(0o700)

        with self.assertRaisesRegex(runloop.RunLoopError, "changed while compiling"):
            runloop.ensure_compiled_launch_helper(
                repository,
                cache_root=cache,
                source_bytes=b"source",
                toolchain_identity_provider=toolchain,
                compiler=mutate_during_compile,
            )

        self.assertEqual(list(cache.glob("*/MacScopeRunLoopLauncher")), [])
        self.assertEqual(list(cache.glob("*/cache-receipt.json")), [])
        self.assertEqual(list(cache.glob("*/launcher.*.out")), [])
        self.assertEqual(events, ["identity", "compile", "identity"])

    def test_compiled_helper_cache_rejects_post_receipt_binary_mutation(self) -> None:
        repository = self.root / "cache-repository"
        repository.mkdir()
        cache = self.root / "external-cache"
        swiftc = self.root / "fixture-swiftc"
        swiftc.write_bytes(b"fixture compiler")
        swiftc.chmod(0o700)
        core: dict[str, object] = {
            "swiftc": {"path": str(swiftc), "sha256": "e" * 64},
        }
        toolchain = {
            **core,
            "identitySha256": runloop._sha256_bytes(runloop._canonical_json(core)),
        }

        def compile_helper(_swiftc: Path, source: Path, output: Path) -> None:
            output.write_bytes(source.read_bytes())

        helper = runloop.ensure_compiled_launch_helper(
            repository,
            cache_root=cache,
            source_bytes=b"source",
            toolchain_identity_provider=lambda: toolchain,
            compiler=compile_helper,
        )
        helper.path.write_bytes(b"mutated")
        helper.path.chmod(0o700)

        with self.assertRaisesRegex(runloop.RunLoopError, "digest"):
            runloop.ensure_compiled_launch_helper(
                repository,
                cache_root=cache,
                source_bytes=b"source",
                toolchain_identity_provider=lambda: toolchain,
                compiler=compile_helper,
            )

    def test_launch_revalidates_compiled_helper_before_process_spawn(self) -> None:
        process_path = self.root / "receipts/process.json"
        helper = self.make_handoff_fixture()
        helper.path.write_bytes(b"mutated after receipt")
        helper.path.chmod(0o700)
        spawned = False

        def popen(*_arguments: object, **_options: object) -> subprocess.Popen[bytes]:
            nonlocal spawned
            spawned = True
            raise AssertionError("mutated helper must not be executed")

        with self.assertRaisesRegex(runloop.RunLoopError, "digest"):
            runloop.begin_launch_handoff(
                Path("/private/tmp/MacScope.app"),
                process_path,
                self.root,
                compiled_helper=helper,
                popen_factory=popen,
            )

        self.assertFalse(spawned)

    def test_handoff_identity_timeout_causes_fixture_cleanup_proof(self) -> None:
        process_path = self.root / "receipts/process.json"
        helper = self.make_handoff_fixture(output_mode="none")

        with self.assertRaisesRegex(runloop.RunLoopError, "timed out"):
            runloop.begin_launch_handoff(
                Path("/private/tmp/MacScope.app"),
                process_path,
                self.root,
                compiled_helper=helper,
                identity_timeout_seconds=0.05,
                ack_timeout_seconds=1.0,
                exit_timeout_seconds=2.0,
            )

        self.assertFalse(runloop._handoff_recovery_path(process_path).exists())

    def test_handoff_parent_ack_timeout_causes_fixture_cleanup_proof(self) -> None:
        process_path = self.root / "receipts/process.json"
        helper = self.make_handoff_fixture()
        handoff = runloop.begin_launch_handoff(
            Path("/private/tmp/MacScope.app"),
            process_path,
            self.root,
            compiled_helper=helper,
            identity_timeout_seconds=1.0,
            ack_timeout_seconds=0.05,
            exit_timeout_seconds=2.0,
        )

        self.assertEqual(handoff.child.wait(timeout=2.0), runloop.HANDOFF_CLEANED_EXIT)
        handoff.abort()
        self.assertFalse(runloop._handoff_recovery_path(process_path).exists())

    def test_preidentity_async_open_timeout_leaves_helper_and_recovery_active(self) -> None:
        process_path = self.root / "receipts/process.json"
        # The helper must still be "opening" when the parent's exit timeout fires.
        helper = self.make_preidentity_handoff_fixture(
            "delayed-no-application", delay_seconds=1.0
        )
        children: list[subprocess.Popen[bytes]] = []

        def capture_popen(*args: object, **kwargs: object) -> subprocess.Popen[bytes]:
            child = subprocess.Popen(*args, **kwargs)  # type: ignore[arg-type]
            children.append(child)
            return child

        with self.assertRaisesRegex(runloop.RunLoopError, "left running"):
            runloop.begin_launch_handoff(
                Path("/private/tmp/MacScope.app"),
                process_path,
                self.root,
                compiled_helper=helper,
                identity_timeout_seconds=0.03,
                ack_timeout_seconds=1.0,
                exit_timeout_seconds=0.03,
                popen_factory=capture_popen,
            )

        self.assertEqual(len(children), 1)
        self.assertIsNone(children[0].poll())
        active = runloop.load_receipt(
            runloop._handoff_recovery_path(process_path), runloop.HANDOFF_SCHEMA
        )
        self.assertEqual(
            stat.S_IMODE(runloop._handoff_recovery_path(process_path).stat().st_mode),
            0o600,
        )
        self.assertIn(active["handoffState"], {"launch-requested", "opening"})
        self.assertFalse(active["cleanupProved"])
        self.assertEqual(children[0].wait(timeout=2.0), runloop.HANDOFF_CLEANED_EXIT)
        terminal = runloop.load_receipt(
            runloop._handoff_recovery_path(process_path), runloop.HANDOFF_SCHEMA
        )
        self.assertEqual(terminal["handoffState"], "no-application")
        self.assertTrue(terminal["cleanupProved"])
        runloop._handoff_recovery_path(process_path).unlink()

    def test_unproved_preidentity_recovery_refuses_a_second_launch(self) -> None:
        process_path = self.root / "receipts/process.json"
        recovery_path = runloop._handoff_recovery_path(process_path)
        runloop.atomic_write_receipt(
            recovery_path,
            {
                "schema": runloop.HANDOFF_SCHEMA,
                "launchNonce": "a" * 32,
                "appBundlePath": "/private/tmp/MacScope.app",
                "helperPID": 123,
                "handoffState": "opening",
                "cleanupProved": False,
            },
        )
        helper = self.make_handoff_fixture()
        spawned = False

        def popen(*_args: object, **_kwargs: object) -> subprocess.Popen[bytes]:
            nonlocal spawned
            spawned = True
            raise AssertionError("unproved recovery must block process spawn")

        with self.assertRaisesRegex(runloop.RunLoopError, "unresolved"):
            runloop.begin_launch_handoff(
                Path("/private/tmp/MacScope.app"),
                process_path,
                self.root,
                compiled_helper=helper,
                popen_factory=popen,
            )

        self.assertFalse(spawned)
        self.assertTrue(recovery_path.exists())

    def test_preidentity_keyboard_interrupt_leaves_unresolved_helper_running(self) -> None:
        process_path = self.root / "receipts/process.json"
        helper = self.make_preidentity_handoff_fixture("delayed-no-application")
        children: list[subprocess.Popen[bytes]] = []

        def capture_popen(*args: object, **kwargs: object) -> subprocess.Popen[bytes]:
            child = subprocess.Popen(*args, **kwargs)  # type: ignore[arg-type]
            children.append(child)
            return child

        with self.assertRaisesRegex(runloop.RunLoopError, "left running"):
            runloop.begin_launch_handoff(
                Path("/private/tmp/MacScope.app"),
                process_path,
                self.root,
                compiled_helper=helper,
                identity_timeout_seconds=1.0,
                ack_timeout_seconds=1.0,
                exit_timeout_seconds=0.03,
                selector_factory=InterruptingSelector,
                popen_factory=capture_popen,
            )

        self.assertEqual(len(children), 1)
        self.assertIsNone(children[0].poll())
        recovery_path = runloop._handoff_recovery_path(process_path)
        active = runloop.load_receipt(recovery_path, runloop.HANDOFF_SCHEMA)
        self.assertFalse(active["cleanupProved"])
        self.assertEqual(children[0].wait(timeout=2.0), runloop.HANDOFF_CLEANED_EXIT)
        terminal = runloop.load_receipt(recovery_path, runloop.HANDOFF_SCHEMA)
        self.assertEqual(terminal["handoffState"], "no-application")
        self.assertTrue(terminal["cleanupProved"])
        recovery_path.unlink()

    def test_preidentity_partial_output_without_helper_recovery_preserves_parent_receipt(self) -> None:
        process_path = self.root / "receipts/process.json"
        helper = self.make_preidentity_handoff_fixture(
            "partial-without-helper-recovery"
        )

        with self.assertRaisesRegex(runloop.RunLoopError, "preserve"):
            runloop.begin_launch_handoff(
                Path("/private/tmp/MacScope.app"),
                process_path,
                self.root,
                compiled_helper=helper,
                identity_timeout_seconds=0.05,
                ack_timeout_seconds=1.0,
                exit_timeout_seconds=2.0,
            )

        recovery = runloop.load_receipt(
            runloop._handoff_recovery_path(process_path), runloop.HANDOFF_SCHEMA
        )
        self.assertEqual(recovery["handoffState"], "launch-requested")
        self.assertFalse(recovery["cleanupProved"])
        self.assertNotIn("pid", recovery)

    def test_preidentity_no_output_without_helper_recovery_preserves_parent_receipt(self) -> None:
        process_path = self.root / "receipts/process.json"
        helper = self.make_preidentity_handoff_fixture(
            "no-output-without-helper-recovery"
        )

        with self.assertRaisesRegex(runloop.RunLoopError, "preserve"):
            runloop.begin_launch_handoff(
                Path("/private/tmp/MacScope.app"),
                process_path,
                self.root,
                compiled_helper=helper,
                identity_timeout_seconds=0.03,
                ack_timeout_seconds=1.0,
                exit_timeout_seconds=2.0,
            )

        recovery = runloop.load_receipt(
            runloop._handoff_recovery_path(process_path), runloop.HANDOFF_SCHEMA
        )
        self.assertEqual(recovery["handoffState"], "launch-requested")
        self.assertFalse(recovery["cleanupProved"])
        self.assertNotIn("pid", recovery)

    def test_preidentity_cleanup_failure_preserves_recovery_without_app_identity(self) -> None:
        process_path = self.root / "receipts/process.json"
        helper = self.make_preidentity_handoff_fixture("cleanup-failed")

        with self.assertRaisesRegex(runloop.RunLoopError, "preserve"):
            runloop.begin_launch_handoff(
                Path("/private/tmp/MacScope.app"),
                process_path,
                self.root,
                compiled_helper=helper,
                identity_timeout_seconds=0.05,
                ack_timeout_seconds=1.0,
                exit_timeout_seconds=2.0,
            )

        recovery_path = runloop._handoff_recovery_path(process_path)
        recovery = runloop.load_receipt(recovery_path, runloop.HANDOFF_SCHEMA)
        self.assertEqual(recovery["handoffState"], "cleanup-failed")
        self.assertFalse(recovery["cleanupProved"])
        self.assertNotIn("pid", recovery)

    def test_handoff_capture_failure_causes_fixture_cleanup_without_ack(self) -> None:
        api = FakeProcessAPI()
        api.alive = False
        process_path = self.root / "receipts/process.json"
        helper = self.make_handoff_fixture()
        with mock.patch.object(
            runloop, "validate_build_receipt", return_value=self.launch_build(api)
        ):
            with self.assertRaisesRegex(runloop.RunLoopError, "capture exact process"):
                runloop.launch_exact_process(
                    self.root / "build.json",
                    process_path,
                    process_api=api,
                    handoff_factory=self.fixture_handoff_factory(helper),
                )

        self.assertFalse(process_path.exists())
        self.assertFalse(runloop._handoff_recovery_path(process_path).exists())

    def test_handoff_receipt_failure_causes_fixture_cleanup_without_ack(self) -> None:
        api = FakeProcessAPI()
        process_path = self.root / "receipts/process.json"
        helper = self.make_handoff_fixture()
        with (
            mock.patch.object(
                runloop, "validate_build_receipt", return_value=self.launch_build(api)
            ),
            mock.patch.object(
                runloop, "atomic_write_receipt", side_effect=OSError("receipt full")
            ),
        ):
            with self.assertRaisesRegex(runloop.RunLoopError, "receipt/readiness"):
                runloop.launch_exact_process(
                    self.root / "build.json",
                    process_path,
                    process_api=api,
                    handoff_factory=self.fixture_handoff_factory(helper),
                    monotonic=lambda: 0.0,
                )

        self.assertFalse(process_path.exists())
        self.assertFalse(runloop._handoff_recovery_path(process_path).exists())

    def test_handoff_success_acks_only_after_provisional_receipt(self) -> None:
        api = FakeProcessAPI()
        process_path = self.root / "receipts/process.json"
        helper = self.make_handoff_fixture(expected_process_receipt=process_path)
        inventory = lambda: [
            {
                "pid": api.pid,
                "executablePath": api.path,
                "finishedLaunching": True,
                "activationPolicy": 0,
            }
        ]
        with mock.patch.object(
            runloop, "validate_build_receipt", return_value=self.launch_build(api)
        ):
            receipt = runloop.launch_exact_process(
                self.root / "build.json",
                process_path,
                process_api=api,
                application_inventory=inventory,
                count_windows=lambda _: 1,
                handoff_factory=self.fixture_handoff_factory(helper),
                monotonic=iter((0.0, 0.1)).__next__,
            )

        self.assertTrue(receipt["firstWindowReady"])
        self.assertEqual(receipt["pid"], api.pid)
        self.assertFalse(runloop._handoff_recovery_path(process_path).exists())
        self.assertEqual(
            runloop.load_receipt(process_path, runloop.PROCESS_SCHEMA), receipt
        )

    def test_verify_requires_matching_build_generation_and_window(self) -> None:
        api = FakeProcessAPI()
        build_path = self.root / "build.json"
        process_path = self.root / "process.json"
        runloop.atomic_write_receipt(process_path, process_receipt(api))
        inventory = lambda: [
            {
                "pid": api.pid,
                "executablePath": api.path,
                "finishedLaunching": True,
                "activationPolicy": 0,
            }
        ]
        with mock.patch.object(
            runloop,
            "validate_build_receipt",
            return_value={
                "buildGeneration": "generation-1",
                "executablePath": api.path,
            },
        ):
            proof = runloop.verify_live_process(
                build_path,
                process_path,
                process_api=api,
                application_inventory=inventory,
                count_windows=lambda pid: 2,
            )
        self.assertEqual(proof["windowCount"], 2)

        with mock.patch.object(
            runloop,
            "validate_build_receipt",
            return_value={
                "buildGeneration": "generation-2",
                "executablePath": api.path,
            },
        ):
            with self.assertRaisesRegex(runloop.RunLoopError, "different build generation"):
                runloop.verify_live_process(
                    build_path,
                    process_path,
                    process_api=api,
                    application_inventory=inventory,
                    count_windows=lambda pid: 2,
                )

    def test_verify_rejects_process_executable_mismatched_to_build(self) -> None:
        api = FakeProcessAPI()
        process_path = self.root / "process.json"
        runloop.atomic_write_receipt(process_path, process_receipt(api))
        with mock.patch.object(
            runloop,
            "validate_build_receipt",
            return_value={
                "buildGeneration": "generation-1",
                "executablePath": "/private/tmp/Other.app/Contents/MacOS/Other",
            },
        ):
            with self.assertRaisesRegex(runloop.RunLoopError, "does not match"):
                runloop.verify_live_process(
                    self.root / "build.json",
                    process_path,
                    process_api=api,
                )

    def test_diagnostics_are_pid_scoped_and_telemetry_is_subsystem_category_scoped(self) -> None:
        logs = runloop.diagnostic_command("logs", 431)
        telemetry = runloop.diagnostic_command("telemetry", 431)

        self.assertEqual(logs[0:2], ["/usr/bin/log", "stream"])
        self.assertEqual(logs[logs.index("--style") + 1], "ndjson")
        self.assertIn("processID == 431", logs[-1])
        self.assertIn("processID == 431", telemetry[-1])
        self.assertIn('subsystem == "org.macscope.MacScope"', telemetry[-1])
        self.assertIn("category != nil", telemetry[-1])

    def test_diagnostics_discard_buffered_bytes_after_pid_reuse(self) -> None:
        api = FakeProcessAPI(reuse_after_reads=5)
        process_path = self.root / "process.json"
        runloop.atomic_write_receipt(process_path, process_receipt(api))
        child = FakeDiagnosticChild(b'{"event":"must-not-escape"}\n')
        output = io.BytesIO()
        commands: list[list[str]] = []

        def popen(command: list[str], **_: object) -> FakeDiagnosticChild:
            commands.append(command)
            return child

        proof = {
            "pid": api.pid,
            "startSeconds": api.start_seconds,
            "startMicroseconds": api.start_microseconds,
            "executablePath": api.path,
        }
        with mock.patch.object(runloop, "verify_live_process", return_value=proof):
            result = runloop.supervise_diagnostics(
                "logs",
                self.root / "build.json",
                process_path,
                process_api=api,
                popen_factory=popen,
                output=output,
                poll_seconds=0.001,
            )

        self.assertEqual(result, 0)
        self.assertEqual(output.getvalue(), b"")
        self.assertTrue(child.terminated)
        self.assertEqual(commands[0][commands[0].index("--style") + 1], "ndjson")

    def test_diagnostics_stop_owned_stream_when_exact_generation_ends(self) -> None:
        api = FakeProcessAPI(reuse_after_reads=3)
        process_path = self.root / "process.json"
        runloop.atomic_write_receipt(process_path, process_receipt(api))
        child = FakeDiagnosticChild()
        proof = {
            "pid": api.pid,
            "startSeconds": api.start_seconds,
            "startMicroseconds": api.start_microseconds,
            "executablePath": api.path,
        }
        with mock.patch.object(runloop, "verify_live_process", return_value=proof):
            result = runloop.supervise_diagnostics(
                "telemetry",
                self.root / "build.json",
                process_path,
                process_api=api,
                popen_factory=lambda *_args, **_kwargs: child,
                output=io.BytesIO(),
                poll_seconds=0.001,
            )

        self.assertEqual(result, 0)
        self.assertTrue(child.terminated)

    def test_diagnostic_selector_failure_occurs_before_child_spawn(self) -> None:
        api = FakeProcessAPI()
        process_path = self.root / "process.json"
        runloop.atomic_write_receipt(process_path, process_receipt(api))
        proof = {
            "pid": api.pid,
            "startSeconds": api.start_seconds,
            "startMicroseconds": api.start_microseconds,
            "executablePath": api.path,
        }
        spawned = False

        def popen(*_arguments: object, **_options: object) -> FakeDiagnosticChild:
            nonlocal spawned
            spawned = True
            return FakeDiagnosticChild()

        with mock.patch.object(runloop, "verify_live_process", return_value=proof):
            with self.assertRaisesRegex(runloop.RunLoopError, "diagnostic selector"):
                runloop.supervise_diagnostics(
                    "logs",
                    self.root / "build.json",
                    process_path,
                    process_api=api,
                    popen_factory=popen,
                    selector_factory=lambda: (_ for _ in ()).throw(OSError("EMFILE")),
                    output=io.BytesIO(),
                )

        self.assertFalse(spawned)

    def test_build_receipt_binds_owner_project_identity_and_dependency_contract(self) -> None:
        (
            repository,
            project,
            app_bundle,
            executable,
            source,
            dependency_contract,
        ) = self.make_build_fixture()
        receipt_path = self.root / "build-receipt.json"
        project_identity = runloop.generated_project_identity(repository)
        with (
            mock.patch.object(runloop, "source_identity", return_value=source),
            mock.patch.object(
                runloop, "verify_dependencies", return_value=dependency_contract
            ),
        ):
            receipt = runloop.record_build(
                repository=repository,
                app_bundle=app_bundle,
                executable=executable,
                configuration="Debug",
                expected_source_identity=str(source["identitySha256"]),
                expected_project_identity=project_identity,
                expected_dependency_identity=str(dependency_contract["identitySha256"]),
                receipt_path=receipt_path,
            )
            self.assertEqual(receipt["dependencyContract"], dependency_contract)
            self.assertEqual(
                receipt["generatedProjectIdentitySha256"], project_identity
            )
            runloop.validate_build_receipt(receipt_path)

            (project / "project.xcproj").write_text("// mutated\n", encoding="utf-8")
            with self.assertRaisesRegex(runloop.RunLoopError, "project no longer matches"):
                runloop.validate_build_receipt(receipt_path)

    def test_generated_project_identity_reuses_owner_symlink_rejection(self) -> None:
        repository, project, *_ = self.make_build_fixture()
        project_file = project / "project.xcproj"
        outside = self.root / "outside-project.xcproj"
        outside.write_text("// outside\n", encoding="utf-8")
        project_file.unlink()
        project_file.symlink_to(outside)

        with self.assertRaisesRegex(runloop.RunLoopError, "contains a symlink"):
            runloop.generated_project_identity(repository)

    def test_build_receipt_rejects_missing_or_mutated_dependency_contract(self) -> None:
        (
            repository,
            _project,
            app_bundle,
            executable,
            source,
            dependency_contract,
        ) = self.make_build_fixture()
        receipt_path = self.root / "build-receipt.json"
        with (
            mock.patch.object(runloop, "source_identity", return_value=source),
            mock.patch.object(
                runloop, "verify_dependencies", return_value=dependency_contract
            ),
        ):
            receipt = runloop.record_build(
                repository=repository,
                app_bundle=app_bundle,
                executable=executable,
                configuration="Debug",
                expected_source_identity=str(source["identitySha256"]),
                expected_project_identity=runloop.generated_project_identity(repository),
                expected_dependency_identity=str(dependency_contract["identitySha256"]),
                receipt_path=receipt_path,
            )

        mutated_contract = dict(dependency_contract)
        mutated_contract["roots"] = {
            "MACSCOPE_GHOSTTY_SURFACE_WORK_ROOT": "/different/root"
        }
        with (
            mock.patch.object(runloop, "source_identity", return_value=source),
            mock.patch.object(
                runloop, "verify_dependencies", return_value=mutated_contract
            ),
        ):
            with self.assertRaisesRegex(runloop.RunLoopError, "dependency contract"):
                runloop.validate_build_receipt(receipt_path)

        receipt.pop("dependencyContract")
        runloop.atomic_write_receipt(receipt_path, receipt)
        with (
            mock.patch.object(runloop, "source_identity", return_value=source),
            mock.patch.object(
                runloop, "verify_dependencies", return_value=dependency_contract
            ),
        ):
            with self.assertRaisesRegex(runloop.RunLoopError, "missing or invalid"):
                runloop.validate_build_receipt(receipt_path)

    def test_build_receipt_dependency_root_disappearance_fails_closed(self) -> None:
        (
            repository,
            _project,
            app_bundle,
            executable,
            source,
            dependency_contract,
        ) = self.make_build_fixture()
        receipt_path = self.root / "build-receipt.json"
        with (
            mock.patch.object(runloop, "source_identity", return_value=source),
            mock.patch.object(
                runloop, "verify_dependencies", return_value=dependency_contract
            ),
        ):
            runloop.record_build(
                repository=repository,
                app_bundle=app_bundle,
                executable=executable,
                configuration="Debug",
                expected_source_identity=str(source["identitySha256"]),
                expected_project_identity=runloop.generated_project_identity(repository),
                expected_dependency_identity=str(dependency_contract["identitySha256"]),
                receipt_path=receipt_path,
            )

        with (
            mock.patch.object(runloop, "source_identity", return_value=source),
            mock.patch.object(
                runloop,
                "verify_dependencies",
                side_effect=runloop.RunLoopError("dependency root is unavailable"),
            ),
        ):
            with self.assertRaisesRegex(runloop.RunLoopError, "root is unavailable"):
                runloop.validate_build_receipt(receipt_path)

    def test_source_identity_changes_for_tracked_and_untracked_bytes(self) -> None:
        repository = self.root / "repository"
        repository.mkdir()
        subprocess.run(["/usr/bin/git", "init", "-q", str(repository)], check=True)
        subprocess.run(
            ["/usr/bin/git", "-C", str(repository), "config", "user.name", "Fixture"],
            check=True,
        )
        subprocess.run(
            [
                "/usr/bin/git",
                "-C",
                str(repository),
                "config",
                "user.email",
                "fixture@invalid",
            ],
            check=True,
        )
        tracked = repository / "Tracked.swift"
        tracked.write_text("let value = 1\n", encoding="utf-8")
        subprocess.run(["/usr/bin/git", "-C", str(repository), "add", "."], check=True)
        subprocess.run(
            ["/usr/bin/git", "-C", str(repository), "commit", "-q", "-m", "fixture"],
            check=True,
        )

        clean = runloop.source_identity(repository)
        tracked.write_text("let value = 2\n", encoding="utf-8")
        changed = runloop.source_identity(repository)
        (repository / "New.swift").write_text("let newValue = 3\n", encoding="utf-8")
        untracked = runloop.source_identity(repository)

        self.assertFalse(clean["dirty"])
        self.assertTrue(changed["dirty"])
        self.assertNotEqual(clean["identitySha256"], changed["identitySha256"])
        self.assertNotEqual(changed["identitySha256"], untracked["identitySha256"])

    def test_dependency_config_rejects_indirection_and_duplicate_roots(self) -> None:
        config = self.root / "DependencyRoots.local.xcconfig"
        config.write_text("ROOT = $(SRCROOT)/indirect\n", encoding="utf-8")
        with self.assertRaisesRegex(runloop.RunLoopError, "empty or indirect"):
            runloop._parse_dependency_config(config)

        config.write_text("ROOT = /first\nROOT = /second\n", encoding="utf-8")
        with self.assertRaisesRegex(runloop.RunLoopError, "more than once"):
            runloop._parse_dependency_config(config)

    def test_helper_has_no_name_wide_process_commands(self) -> None:
        source = MODULE_PATH.read_text(encoding="utf-8")
        for forbidden in ("pgrep", "pkill", "killall", "lsof"):
            self.assertNotIn(forbidden, source)
        self.assertIn("createsNewApplicationInstance = true", source)
        self.assertIn("openApplication(", source)
        self.assertIn("application.terminate()", source)
        self.assertIn("application.forceTerminate()", source)
        self.assertIn("application.isTerminated", source)
        self.assertNotIn('"swift",\n                "-parse-as-library"', source)
        self.assertNotIn("os.execv", source)
        self.assertIn("_generated_project_identity", source)


if __name__ == "__main__":
    unittest.main()
