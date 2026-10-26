#!/usr/bin/env python3
"""Govern the isolated native sanitizer lanes without instrumenting shipping builds."""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path
from unittest.mock import patch
from Scripts.lib.work_root import existing_work_root, work_root as macscope_work_root


ROOT = Path(__file__).resolve().parents[2]
RUNNER = ROOT / "Scripts/native-decompiler-xpc/run_native_bridge_sanitizers.sh"
GOLDEN = ROOT / "Scripts/native-decompiler-xpc/run_native_bridge_golden.sh"
PROJECT = ROOT / "MacScope/project.yml"
PRODUCTION_RUNNER = ROOT / "Scripts/native-decompiler-xpc/build_native_bridge.sh"
CI_WORKFLOW = ROOT / ".github/workflows/ci.yml"


class NativeDecompilerSanitizerLaneTests(unittest.TestCase):
    def test_runner_fixture_falls_back_when_preferred_temp_parent_is_absent(self) -> None:
        preferred = existing_work_root() or macscope_work_root()
        actual_is_dir = Path.is_dir
        actual_temporary_directory = tempfile.TemporaryDirectory

        def is_dir(path: Path) -> bool:
            return False if path == preferred else actual_is_dir(path)

        def temporary_directory(*args, **kwargs):
            if kwargs.get("dir") is not None and Path(kwargs["dir"]) == preferred:
                raise FileNotFoundError("simulated unavailable preferred temp parent")
            return actual_temporary_directory(*args, **kwargs)

        with patch.object(Path, "is_dir", is_dir), patch.object(tempfile, "TemporaryDirectory", temporary_directory):
            try:
                result, calls = self.run_runner_fixture("address")
            except FileNotFoundError as error:
                self.fail(f"fixture did not fall back to the available system temp parent: {error}")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(sum(call[0] == "ctest" for call in calls), 1)

    def run_runner_fixture(self, profile: str, failure: str = "") -> tuple[subprocess.CompletedProcess[str], list[list[str]]]:
        """Exercise the real runner, replacing only costly external producers/tools."""
        preferred_parent = existing_work_root() or macscope_work_root()
        with tempfile.TemporaryDirectory(dir=preferred_parent if preferred_parent.is_dir() else None) as directory:
            root = Path(directory)
            repo = root / "repo"
            runner = repo / "Scripts/native-decompiler-xpc/run_native_bridge_sanitizers.sh"
            runner.parent.mkdir(parents=True)
            shutil.copy2(RUNNER, runner)
            source = repo / "Tools/NativeDecompilerBridge"
            source.mkdir(parents=True)
            ordinary = root / "ordinary-materialization"
            ordinary.mkdir()
            tools = root / "tools"
            tools.mkdir()
            trace = root / "trace.jsonl"

            def executable(path: Path, body: str) -> None:
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text("#!/usr/bin/env python3\n" + textwrap.dedent(body), encoding="utf-8")
                path.chmod(0o755)

            executable(runner.parent / "native_decompiler_source_identity.py", 'print("f" * 64)\n')
            executable(tools / "uname", 'print("arm64")\n')
            executable(tools / "xcrun", 'print("/usr/bin/true")\n')
            tool_body = '''
                import json, os, pathlib, sys
                name = pathlib.Path(sys.argv[0]).name
                args = sys.argv[1:]
                with open(os.environ["TRACE_PATH"], "a", encoding="utf-8") as stream:
                    stream.write(json.dumps([name, *args]) + "\\n")
                if name == "build_vendored_sleigh_native_source.sh":
                    if os.environ.get("FAIL_STAGE") == "builder":
                        sys.exit(23)
                    work = pathlib.Path(args[args.index("--work-root") + 1])
                    profile = args[args.index("--sanitizer") + 1]
                    (work / ("SleighNativeSource-" + profile) / "materialization").mkdir(parents=True)
                elif name == "verify_sleigh_package.py":
                    if "--expected-sanitizer" in args and os.environ.get("FAIL_STAGE") == "profile":
                        sys.exit(24)
                elif name == "cmake" and "-B" in args:
                    build = pathlib.Path(args[args.index("-B") + 1])
                    build.mkdir(parents=True, exist_ok=True)
                    (build / "build.ninja").write_text("-fsanitize=address -fno-omit-frame-pointer -fsanitize=undefined -fno-sanitize-recover=all")
                '''
            for name in ("cmake", "ctest", "ninja"):
                executable(tools / name, tool_body)
            executable(repo / "Scripts/dependencies/build_vendored_sleigh_native_source.sh", tool_body)
            executable(repo / "Scripts/native-decompiler-direct/verify_sleigh_package.py", tool_body)
            environment = {
                **os.environ,
                "PATH": str(tools) + os.pathsep + os.environ["PATH"],
                "MACSCOPE_TOOL_SEARCH_PATH": str(tools),
                "TRACE_PATH": str(trace),
                "FAIL_STAGE": failure,
            }
            result = subprocess.run(
                ["/bin/bash", str(runner), "--source-root", str(source),
                 "--build-root", str(root / "build"), "--materialization-root", str(ordinary),
                 "--sanitizer", profile],
                env=environment, text=True, capture_output=True, check=False,
            )
            calls = [json.loads(line) for line in trace.read_text().splitlines()] if trace.exists() else []
            return result, calls

    def test_runner_builds_matching_native_profile_before_bridge_configuration(self) -> None:
        for profile in ("address", "undefined"):
            with self.subTest(profile=profile):
                result, calls = self.run_runner_fixture(profile)
                self.assertEqual(result.returncode, 0, result.stderr)
                producers = [call for call in calls if call[0] == "build_vendored_sleigh_native_source.sh"]
                self.assertEqual(len(producers), 1, calls)
                self.assertEqual(producers[0][producers[0].index("--sanitizer") + 1], profile)
                configure = next(call for call in calls if call[0] == "cmake" and "-S" in call)
                materialization = next(arg for arg in configure if arg.startswith("-DMACSCOPE_SLEIGH_MATERIALIZATION_ROOT="))
                self.assertTrue(materialization.endswith(f"/SleighNativeSource-{profile}/materialization"), materialization)
                self.assertLess(calls.index(producers[0]), calls.index(configure))
                admission = [call for call in calls if call[0] == "verify_sleigh_package.py" and "--expected-sanitizer" in call]
                self.assertEqual(len(admission), 1, calls)
                self.assertEqual(admission[0][admission[0].index("--expected-sanitizer") + 1], profile)
                self.assertLess(calls.index(admission[0]), calls.index(configure))
                self.assertEqual(calls[-1][0], "ctest")
                self.assertIn("--no-tests=error", calls[-1])
                self.assertEqual(sum(call[0] == "ctest" for call in calls), 1)

    def test_runner_stops_before_bridge_when_native_producer_or_profile_admission_fails(self) -> None:
        for failure, expected_status in (("builder", 23), ("profile", 24)):
            with self.subTest(failure=failure):
                result, calls = self.run_runner_fixture("address", failure)
                self.assertEqual(result.returncode, expected_status, result.stderr)
                self.assertFalse(any(call[0] in ("cmake", "ctest") for call in calls), calls)

    def test_runner_freezes_both_sanitizer_fail_closed_contracts(self) -> None:
        text = RUNNER.read_text(encoding="utf-8")
        for fragment in (
            "-fsanitize=address",
            "-fno-omit-frame-pointer",
            "-fsanitize=undefined",
            "-fno-sanitize-recover=all",
            "ASAN_OPTIONS",
            "UBSAN_OPTIONS",
            "halt_on_error=1",
            "MACSCOPE_NATIVE_CTEST_JOBS",
            "hw.perflevel0.logicalcpu",
            '"$ctest_bin" --test-dir "$build_root" --parallel "$native_ctest_jobs" --output-on-failure',
        ):
            self.assertIn(fragment, text, fragment)

    def test_production_archive_build_remains_unsanitized(self) -> None:
        self.assertNotIn("-fsanitize", PROJECT.read_text(encoding="utf-8"))
        self.assertNotIn("-fsanitize", PRODUCTION_RUNNER.read_text(encoding="utf-8"))

    def test_objc_wire_codec_golden_executable_runs_under_asan(self) -> None:
        text = GOLDEN.read_text(encoding="utf-8")
        self.assertRegex(
            text,
            r'compile_objc_bridge_test "\$objc_test"\s*\\\s*\n\s*'
            r'"\$contract_source/CanonicalRequest.cpp"\s*\\\s*\n\s*'
            r'-fsanitize=address -fno-omit-frame-pointer',
        )
        self.assertIn('compile_objc_bridge_test "$package_objc_test"', text)
        self.assertNotRegex(
            text,
            r'compile_objc_bridge_test "\$package_objc_test"\s*\\\s*\n\s*-fsanitize',
        )
        self.assertIn("ASAN_OPTIONS=detect_leaks=0:halt_on_error=1:abort_on_error=1", text)

    def test_self_hosted_xcode_lane_runs_both_isolated_sanitizers(self) -> None:
        text = CI_WORKFLOW.read_text(encoding="utf-8")
        runner = "./Scripts/native-decompiler-xpc/run_native_bridge_sanitizers.sh"
        self.assertEqual(text.count(runner), 2)
        self.assertIn('--sanitizer address', text)
        self.assertIn('--sanitizer undefined', text)
        self.assertIn('value["sleigh_materialization_root"]', text)
        self.assertIn('max(paths, key=lambda path: path.stat().st_mtime_ns)', text)
        self.assertNotIn('/usr/bin/sort | /usr/bin/tail -1', text)
        # D9: one persistent warm run root, never a fresh root per run.
        self.assertIn('MACSCOPE_QUALIFICATION_WORK_ROOT_NAME: macscope-qualification-nightly', text)
        self.assertNotIn('macscope-qualification-${{ github.run_id }}', text)
        self.assertEqual(
            text.count('$MACSCOPE_CI_QUALIFICATION_ROOT/$MACSCOPE_QUALIFICATION_WORK_ROOT_NAME'), 4
        )
        self.assertIn('--build-root "$RUNNER_TEMP/macscope-native-sanitizers"', text)


if __name__ == "__main__":
    unittest.main()
