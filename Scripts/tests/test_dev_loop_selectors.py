#!/usr/bin/env python3
"""dev_loop.sh refuses an empty selector list instead of running the whole bundle (D12)."""

from __future__ import annotations

from pathlib import Path
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[2]
DEV_LOOP = ROOT / "Scripts/dev_loop.sh"


class DevLoopSelectorTests(unittest.TestCase):
    def run_dev_loop(self, *arguments: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(["/bin/bash", str(DEV_LOOP), *arguments],
                              capture_output=True, text=True, timeout=30)

    def test_empty_selector_list_is_refused_before_any_work(self) -> None:
        result = self.run_dev_loop()
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn("give at least one CoreTests/<Suite> selector", result.stderr)

    def test_malformed_selector_is_still_refused(self) -> None:
        result = self.run_dev_loop("NotCoreTests/X")
        self.assertEqual(result.returncode, 2, result.stderr)

    def scheme(self, *selectors: str) -> str:
        result = subprocess.run(["/bin/bash", str(DEV_LOOP), *selectors], capture_output=True, text=True,
                                timeout=30, env={"PATH": "/usr/bin:/bin", "MACSCOPE_DEV_PRINT_SCHEME": "1"})
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout.strip()

    def test_a_single_bundle_builds_only_that_bundle(self) -> None:
        self.assertEqual(self.scheme("CoreTests/ImageLayoutTests"), "CoreTests")
        self.assertEqual(self.scheme("Phase2Tests/X", "Phase2Tests/Y/testZ"), "Phase2Tests")
        self.assertEqual(self.scheme("Phase2Tests"), "Phase2Tests")

    def test_native_verbose_needs_no_selector(self) -> None:
        self.assertEqual(self.scheme("--native-verbose"), "CoreTests")

    def test_native_verbose_runs_between_prepare_and_the_xcode_build(self) -> None:
        script = DEV_LOOP.read_text(encoding="utf-8")
        prepare = script.index('build_and_run.sh" --prepare')
        native = script.index('dev_dependency_cache.py" \\')
        build = script.index("build-for-testing ||")
        self.assertLess(prepare, native)
        self.assertLess(native, build)

    def test_tests_run_with_a_bounded_per_test_time_allowance(self) -> None:
        script = DEV_LOOP.read_text(encoding="utf-8")
        self.assertIn('TEST_TIMEOUT_SECONDS="${MACSCOPE_DEV_TEST_TIMEOUT_SECONDS:-300}"', script)
        start = script.index("TEST_STATUS=0\n")
        fragment = script[start:script.index('TESTED="$(clock)"', start)]
        for timeout in ("300", "0"):
            for parallel in ("1", "0"):
                with self.subTest(timeout=timeout, parallel=parallel):
                    result = subprocess.run(
                        ["/bin/bash", "-euc",
                         'capture() { printf "%s\\n" "$@"; }\n'
                         'XCODEBUILD=(capture)\nONLY_TESTING=(-only-testing:CoreTests/Fixture)\n' + fragment],
                        env={"PATH": "/usr/bin:/bin", "BUILD_STATUS": "0", "BUILD_ONLY": "0",
                             "TEST_TIMEOUT_SECONDS": timeout, "MACSCOPE_DEV_PARALLEL_TESTING": parallel},
                        capture_output=True, text=True,
                    )
                    self.assertEqual(result.returncode, 0, result.stderr)
                    expected = ["-only-testing:CoreTests/Fixture"]
                    if timeout != "0":
                        expected += ["-test-timeouts-enabled", "YES",
                                     "-default-test-execution-time-allowance", timeout,
                                     "-maximum-test-execution-time-allowance", timeout]
                    if parallel == "0":
                        expected += ["-parallel-testing-enabled", "NO"]
                    self.assertEqual(result.stdout.splitlines(), expected + ["test-without-building"])

    def test_selectors_from_both_bundles_build_both(self) -> None:
        self.assertEqual(self.scheme("CoreTests/A", "Phase2Tests/B"), "MacScopeApp")

    def test_whole_bundle_needs_an_explicit_coretests_selector(self) -> None:
        script = DEV_LOOP.read_text(encoding="utf-8")
        self.assertNotIn("SELECTORS=(CoreTests)\nfi", script)
        self.assertIn('if [[ "${BUILD_ONLY}" == 1 ]]; then\n    SELECTORS=(CoreTests)', script)


if __name__ == "__main__":
    unittest.main()
