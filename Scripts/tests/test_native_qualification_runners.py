"""Execute the real native runners against synthetic, build-free tool boundaries."""
from __future__ import annotations

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import unittest

from Scripts.tests import test_native_qualification_report as report_fixtures


ROOT = Path(__file__).resolve().parents[2]
MARKER = "MACSCOPE_NATIVE_QUALIFICATION_REPORT="


class NativeQualificationRunnerTests(unittest.TestCase):
    def fixture(self, profile="none", failure=""):
        fixture = report_fixtures.NativeQualificationReportTests()
        fixture.setUp()
        self.addCleanup(fixture.doCleanups)
        if profile != "none":
            old = fixture.build
            fixture.build = fixture.root / profile
            old.rename(fixture.build)
            for relative in ("CMakeCache.txt", "compile_commands.json"):
                path = fixture.build / relative
                path.write_text(path.read_text().replace(str(old), str(fixture.build)))
            for row in fixture.inventory["tests"]:
                row["command"][0] = row["command"][0].replace(str(old), str(fixture.build))
            fixture.report = fixture.build / "qualification"
        fixture.trace = fixture.root / "runner-tools.jsonl"
        fixture.executable(fixture.cmake, f"""
import json, sys
from pathlib import Path
if sys.argv[1:] == ['--version']:
    print('cmake version 4.1.0'); raise SystemExit(0)
with Path({str(fixture.trace)!r}).open('a') as out: out.write(json.dumps(['cmake', *sys.argv[1:]]) + '\\n')
""")
        # CTest's inventory probe and actual test process are distinguished in
        # the trace. This fixture fails empty ordinary runs only if the runner
        # supplies CTest's explicit no-tests guard.
        fixture.executable(fixture.ctest, f"""
import json, os, sys
from pathlib import Path
if sys.argv[1:] == ['--version']:
    print('ctest version 4.1.0'); raise SystemExit(0)
plan = json.loads(Path({str(fixture.plan)!r}).read_text())
with Path({str(fixture.calls)!r}).open('a') as out: out.write(json.dumps(sys.argv[1:]) + '\\n')
if '--show-only=json-v1' in sys.argv:
    print(json.dumps(plan['inventory'])); raise SystemExit(0)
if plan.get('mutate'):
    target = Path(plan['mutate']); target.write_bytes(target.read_bytes() + b'\\nsource drift\\n')
if '--output-junit' in sys.argv:
    Path(sys.argv[sys.argv.index('--output-junit') + 1]).write_text(plan['xml'])
print('synthetic CTest output', flush=True)
if plan.get('empty') and '--no-tests=error' in sys.argv: raise SystemExit(8)
raise SystemExit(plan['exit'])
""")
        tools = fixture.root / "tools"
        # Apple's /usr/bin/python3 launcher delegates through the selected
        # developer directory; keep that boundary synthetic as well.
        fixture.executable(fixture.dev / "usr/bin/xcrun", "import os, sys\nargs = sys.argv[1:]\nif args and args[0] == 'python3': args.pop(0)\nos.execv(" + repr(sys.executable) + ", [" + repr(sys.executable) + ", *args])")
        fixture.executable(tools / "uname", "print('arm64')")
        fixture.executable(tools / "ninja", "pass")
        fixture.executable(tools / "file", "print('Mach-O 64-bit executable arm64')")
        fixture.executable(tools / "strings", "print('/Users/fixture/leak' if __import__('os').environ.get('FAIL_STAGE') == 'private-path' else '')")
        fixture.executable(tools / "xcrun", f"""
import os, sys
args = sys.argv[1:]
if args == ['--find', 'clang++']: print({str(fixture.compiler)!r})
elif args == ['--sdk', 'macosx', '--show-sdk-path']: print({str(fixture.sdk)!r})
elif args[:2] == ['lipo', '-archs']: print('x86_64' if os.environ.get('FAIL_STAGE') == 'linkage' else 'arm64')
elif args[:2] == ['otool', '-l']: print('cmd LC_BUILD_VERSION')
elif args[:2] == ['otool', '-L']: print('probe:\\n/usr/lib/libz.1.dylib (compatibility version 1)\\n/usr/lib/libc++.1.dylib (compatibility version 1)\\n/usr/lib/libSystem.B.dylib (compatibility version 1)')
else: raise SystemExit('unexpected xcrun fixture invocation: ' + repr(args))
""")
        fixture.environment = {**os.environ, "DEVELOPER_DIR": str(fixture.dev),
            "PATH": str(tools) + os.pathsep + os.environ["PATH"],
            "MACSCOPE_TOOL_SEARCH_PATH": str(tools), "MACSCOPE_CMAKE": str(fixture.cmake),
            "MACSCOPE_CTEST": str(fixture.ctest), "MACSCOPE_NATIVE_CTEST_JOBS": "3",
            "CMAKE_BUILD_PARALLEL_LEVEL": "2", "FAIL_STAGE": failure}
        fixture.profile = profile
        runner_name = "build_native_bridge.sh" if profile == "none" else "run_native_bridge_sanitizers.sh"
        fixture.runner = fixture.repo / "Scripts/native-decompiler-xpc" / runner_name
        shutil.copyfile(ROOT / "Scripts/native-decompiler-xpc" / runner_name, fixture.runner)
        if profile != "none":
            fixture.ordinary = fixture.root / "ordinary"
            shutil.copytree(fixture.material, fixture.ordinary)
            fixture.sanitizer_fixture(profile)
            (fixture.build / "build.ninja").write_text(" ".join(fixture.module.sleigh_package.SANITIZER_FLAGS[profile]))
            # The costly producer is synthetic; the resulting schema-3 archive
            # and compiler/profile validation remain real.
            fixture.executable(fixture.repo / "Scripts/dependencies/build_vendored_sleigh_native_source.sh", f"""
import json, os, sys
from pathlib import Path
with Path({str(fixture.trace)!r}).open('a') as out: out.write(json.dumps(['producer', *sys.argv[1:]]) + '\\n')
if os.environ.get('FAIL_STAGE') == 'producer': raise SystemExit(23)
""")
        fixture.save_plan()
        return fixture

    def invoke(self, fixture, report=True, report_path=None):
        source = fixture.repo / "Tools/NativeDecompilerBridge"
        args = ["/bin/bash", str(fixture.runner), "--source-root", str(source),
            "--build-root", str(fixture.build if fixture.profile == "none" else fixture.build.parent),
            "--materialization-root", str(fixture.material if fixture.profile == "none" else fixture.ordinary)]
        if fixture.profile == "none":
            args += ["--wrapper-revision", fixture.module.source_identity.profile_digest(fixture.repo, "wrapper"),
                "--configuration", "Release"]
        else:
            args += ["--sanitizer", fixture.profile]
        if report:
            args += ["--qualification-report-dir", str(fixture.report if report_path is None else report_path)]
        result = subprocess.run(args, env=fixture.environment, text=True, capture_output=True, check=False, timeout=30)
        calls = [json.loads(line) for line in fixture.calls.read_text().splitlines()] if fixture.calls.exists() else []
        fixture.executions = [call for call in calls if "--show-only=json-v1" not in call]
        return result

    def test_runner_default_executes_once_and_emits_existing_contract(self):
        for profile in ("none", "address", "undefined"):
            for empty in (False, True):
                with self.subTest(profile=profile, empty=empty):
                    fixture = self.fixture(profile)
                    fixture.save_plan(empty=empty)
                    result = self.invoke(fixture, report=False)
                    self.assertEqual(result.returncode, 8 if empty else 0, result.stderr)
                    self.assertEqual(len(fixture.executions), 1)
                    self.assertIn("--no-tests=error", fixture.executions[0])
                    self.assertNotIn(MARKER, result.stdout)
                    self.assertFalse(fixture.report.exists())
                    if profile == "none" and not empty:
                        for field in ("archive=", "link_inputs=", "representative_binary=", "inspection="):
                            self.assertIn(field, result.stdout)

    def test_report_retains_one_execution_for_all_profiles(self):
        for profile in ("none", "address", "undefined"):
            with self.subTest(profile=profile):
                fixture = self.fixture(profile)
                result = self.invoke(fixture)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(len(fixture.executions), 1)
                self.assertEqual(result.stdout.count(MARKER), 1)
                value = json.loads((fixture.report / "native-qualification.json").read_text())
                self.assertEqual(value["profile"], profile)
                execution = json.loads((fixture.report / "ctest.execution.json").read_text())
                self.assertEqual(len(execution["tests"]), 21)
                self.assertTrue(all(row["status"] == "passed" for row in execution["tests"]))
                calls = [json.loads(line) for line in fixture.trace.read_text().splitlines()]
                configured = next(row for row in calls if row[0] == "cmake" and "-S" in row)
                for setting in ("-DBUILD_TESTING=ON", "-DMACSCOPE_ENABLE_GHIDRA_PROVIDER=ON",
                                "-DMACSCOPE_ENABLE_SLEIGH_DECOMP_API_PROBE=OFF", "-DCMAKE_EXPORT_COMPILE_COMMANDS=ON"):
                    self.assertIn(setting, configured)

    def test_report_marker_follows_final_native_checks(self):
        for failure in ("linkage", "private-path", "source"):
            with self.subTest(failure=failure):
                fixture = self.fixture(failure=failure)
                if failure == "source":
                    fixture.save_plan(mutate=str(fixture.repo / "Tools/NativeDecompilerBridge/src/CanonicalRequest.cpp"))
                result = self.invoke(fixture)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(len(fixture.executions), 1)
                self.assertEqual(json.loads((fixture.report / "ctest.execution.json").read_text())["exit_code"], 0)
                self.assertNotIn(MARKER, result.stdout)
                self.assertFalse((fixture.report / "native-qualification.json").exists())

    def test_invalid_report_root_rejects_before_tests(self):
        for profile in ("none", "address"):
            for kind in ("existing", "outside", "relative"):
                with self.subTest(profile=profile, kind=kind):
                    fixture = self.fixture(profile)
                    report = fixture.report
                    if kind == "existing": report.mkdir()
                    elif kind == "outside": report = fixture.root / "outside-report"
                    else: report = Path("relative-report")
                    result = self.invoke(fixture, report_path=report)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertEqual(fixture.executions, [])
                    self.assertNotIn(MARKER, result.stdout)

    def test_sanitizer_profile_or_source_drift_prevents_publication(self):
        for profile in ("address", "undefined"):
            for failure in ("instrumentation", "borrowed", "mixed", "source", "producer", "product"):
                with self.subTest(profile=profile, failure=failure):
                    fixture = self.fixture(profile, failure)
                    if failure == "instrumentation":
                        path = fixture.build / "compile_commands.json"
                        path.write_text(path.read_text().replace("-fsanitize=" + profile, "-fsanitize=none"))
                    elif failure in ("borrowed", "mixed"):
                        archives = ("libdecomp.a", "libsla.a") if failure == "borrowed" else ("libsla.a",)
                        for name in archives:
                            shutil.copyfile(fixture.ordinary / "package/lib" / name,
                                            fixture.material / "package/lib" / name)
                    elif failure in ("source", "product"):
                        target = fixture.repo / "Tools/NativeDecompilerBridge/src/CanonicalRequest.cpp" if failure == "source" else fixture.build / "libmacscope_native_decompiler_contract.a"
                        fixture.save_plan(mutate=str(target))
                    result = self.invoke(fixture)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertLessEqual(len(fixture.executions), 1)
                    if failure in ("source", "product"):
                        self.assertEqual(len(fixture.executions), 1)
                        self.assertEqual(json.loads((fixture.report / "ctest.execution.json").read_text())["exit_code"], 0)
                    self.assertNotIn(MARKER, result.stdout)
                    self.assertFalse((fixture.report / "native-qualification.json").exists())

    def test_ctest_failure_keeps_exit_and_diagnostics_without_rerun(self):
        for profile in ("none", "undefined"):
            with self.subTest(profile=profile):
                fixture = self.fixture(profile)
                fixture.save_plan(exit=7)
                result = self.invoke(fixture)
                self.assertEqual(result.returncode, 7, result.stderr)
                self.assertEqual(len(fixture.executions), 1)
                self.assertTrue((fixture.report / "ctest.execution.json").exists())
                self.assertIn("synthetic CTest output", result.stdout)
                self.assertNotIn(MARKER, result.stdout)

    def test_offline_runner_has_no_acquisition_fallback(self):
        for profile in ("none", "address"):
            with self.subTest(profile=profile):
                fixture = self.fixture(profile)
                material = fixture.material if profile == "none" else fixture.ordinary
                (material / "MATERIALIZATION.json").unlink()
                acquisition = fixture.root / "acquisition.jsonl"
                for name in ("curl", "git", "wget"):
                    fixture.executable(fixture.root / "tools" / name,
                        "from pathlib import Path\nPath(" + repr(str(acquisition)) + ").write_text('acquisition attempted')\nraise SystemExit(99)")
                result = self.invoke(fixture)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(fixture.executions, [])
                self.assertFalse(fixture.trace.exists())
                self.assertFalse(acquisition.exists())
                self.assertNotIn(MARKER, result.stdout)


if __name__ == "__main__":
    unittest.main()
