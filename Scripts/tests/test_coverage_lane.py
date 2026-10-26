#!/usr/bin/env python3

from __future__ import annotations

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
QUALIFIER = ROOT / "Scripts/qualify_local_private_build.sh"
PROJECT_YML = ROOT / "MacScope/project.yml"


class CoverageLaneTests(unittest.TestCase):
    def test_coverage_is_confined_to_full_test_qualification(self) -> None:
        script = QUALIFIER.read_text(encoding="utf-8")
        shared_start = script.index("XCODEBUILD=(")
        shared_end = script.index("\n)", shared_start)
        shared = script[shared_start:shared_end]
        full_test = script[script.index("  full-test)"):script.index("    ;;", script.index("  full-test)"))]
        release = script[script.index("  release)"):script.index("    ;;", script.index("  release)"))]

        # Full qualification prepares both test products, then executes the
        # CoreTests product without rebuilding. Coverage stays on those three
        # Debug actions only, not on either Release build path.
        self.assertEqual(script.count("-enableCodeCoverage YES"), 3)
        self.assertEqual(script.count("-enableCodeCoverage NO"), 0)
        self.assertEqual(script.count("CLANG_COVERAGE_MAPPING=NO"), 2)
        full_release = full_test[full_test.index('timed_xcode_stage xcode.release-build'):]
        self.assertIn("CLANG_COVERAGE_MAPPING=NO build", full_release)
        self.assertNotIn("-enableCodeCoverage", full_release)
        self.assertEqual(full_test.count("CLANG_COVERAGE_MAPPING=NO"), 1)
        self.assertEqual(release.count("CLANG_COVERAGE_MAPPING=NO"), 1)
        self.assertIn("-enableCodeCoverage YES", full_test)
        self.assertNotIn("-enableCodeCoverage", shared)
        self.assertIn("CLANG_COVERAGE_MAPPING=NO", release)
        self.assertNotIn("-enableCodeCoverage", release)
        self.assertIn("xcrun xccov view --report --json", full_test)
        self.assertIn("MACSCOPE_COVERAGE_JSON=", full_test)
        self.assertEqual(script.count("LLVM_PROFILE_FILE="), 1)
        self.assertIn(
            'COVERAGE_PROFILE_ROOT="${RUN_ROOT}/CoverageProfiles"',
            full_test,
        )
        self.assertIn(
            '/usr/bin/env "LLVM_PROFILE_FILE=${COVERAGE_PROFILE_ROOT}/%p-%m.profraw"',
            full_test,
        )
        self.assertNotIn("LLVM_PROFILE_FILE", shared)
        self.assertNotIn("LLVM_PROFILE_FILE", release)

    def test_coverage_is_disabled_in_release_without_project_wide_enablement(self) -> None:
        project = PROJECT_YML.read_text(encoding="utf-8")
        for forbidden in (
            "CLANG_COVERAGE_MAPPING",
            "SWIFT_ENABLE_CODE_COVERAGE",
            "GCC_GENERATE_TEST_COVERAGE",
        ):
            self.assertNotIn(forbidden, project)
        base = project[project.index("  base:\n"):project.index("  configs:\n")]
        configs = project[project.index("  configs:\n"):project.index("targets:\n")]
        release = configs[configs.index("    Release:\n"):]
        self.assertNotIn("ENABLE_CODE_COVERAGE", base)
        self.assertEqual(project.count("ENABLE_CODE_COVERAGE: NO"), 1)
        self.assertIn("ENABLE_CODE_COVERAGE: NO", release)

    def test_macscope_scheme_gathers_coverage_for_the_app_only(self) -> None:
        project = PROJECT_YML.read_text(encoding="utf-8")
        schemes = project[project.index("schemes:\n"):]
        macscope = schemes[
            schemes.index("  MacScopeApp:\n"):
            schemes.index("  MacScopeInstalledAppUITests:\n")
        ]
        expected = (
            "    test:\n"
            "      gatherCoverageData: true\n"
            "      coverageTargets:\n"
            "        - MacScopeApp\n"
            "      targets:\n"
        )
        self.assertIn(expected, macscope)
        # CoreTests is the only test target, run class-parallel (R10.7).
        self.assertIn("        - name: CoreTests\n          parallelizable: true\n", macscope)
        self.assertEqual(project.count("gatherCoverageData: true"), 1)
        self.assertEqual(project.count("coverageTargets:"), 1)


if __name__ == "__main__":
    unittest.main()
