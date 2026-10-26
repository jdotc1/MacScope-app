#!/usr/bin/env python3

from __future__ import annotations

import importlib.util
import json
import hashlib
import subprocess
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
MODULE_PATH = ROOT / "Scripts/build_economics.py"
PROJECT_YML = ROOT / "MacScope/project.yml"
RECEIPT = ROOT / "docs/perf/BUILD_ECONOMICS.json"
MEASUREMENT_SCRIPT = ROOT / "Scripts/measure_build_economics.sh"


def load_module():
    specification = importlib.util.spec_from_file_location("build_economics", MODULE_PATH)
    if specification is None or specification.loader is None:
        raise AssertionError("could not load build-economics module")
    module = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(module)
    return module


build_economics = load_module()


class BuildEconomicsReceiptTests(unittest.TestCase):

    def test_measurement_harness_pins_the_existing_debug_build_shape(self) -> None:
        script = MEASUREMENT_SCRIPT.read_text(encoding="utf-8")

        for required in (
            "-configuration Debug",
            "-destination 'platform=macOS,arch=arm64'",
            "-disableAutomaticPackageResolution",
            "-showBuildTimingSummary",
            '"MACSCOPE_GHOSTTY_SURFACE_WORK_ROOT=${GHOSTTY_SURFACE_WORK_ROOT}"',
            '"MACSCOPE_GHOSTTY_SURFACE_SOURCE_DIR=${GHOSTTY_SURFACE_SOURCE_DIR}"',
            '"MACSCOPE_GHOSTTY_SURFACE_ARTIFACT_ROOT=${GHOSTTY_SURFACE_ARTIFACT_ROOT}"',
            '"MACSCOPE_GHOSTTY_SURFACE_FRAMEWORK=${GHOSTTY_SURFACE_FRAMEWORK}"',
            '"MACSCOPE_SLEIGH_MATERIALIZATION_ROOT=${SLEIGH_MATERIALIZATION_ROOT}"',
            '"MACSCOPE_MACHOKIT_MATERIALIZATION_ROOT=${MACHOKIT_MATERIALIZATION_ROOT}"',
            "COMPILER_INDEX_STORE_ENABLE=NO",
            'DERIVED_DATA="${RUN_ROOT}/DerivedData"',
            'WORK_ROOT_REAL=',
        ):
            self.assertIn(required, script)
        self.assertNotIn("MACSCOPE_GHOSTTY_SOURCE_DIR=", script)
        self.assertNotIn("MACSCOPE_GHOSTTY_VT_WORK_ROOT=", script)
        self.assertNotIn('"${SCRIPT_DIR}/bootstrap.sh"', script)
        self.assertNotIn("curl", script)
        self.assertNotIn("git clone", script)
        self.assertNotIn("-enableCodeCoverage", script)
        self.assertEqual(script.count('measure "${'), 2)

    def test_release_uses_measured_parallel_single_file_compilation(self) -> None:
        project = PROJECT_YML.read_text(encoding="utf-8")
        configs = project[project.index("  configs:\n"):project.index("targets:\n")]
        debug = configs[:configs.index("    Release:\n")]
        release = configs[configs.index("    Release:\n"):]

        self.assertIn('SWIFT_OPTIMIZATION_LEVEL: "-Onone"', debug)
        # PERF-A (6f8aea688) pins Release to the standard "-O" explicitly; any
        # other level (-Osize, -Onone, -Ounchecked) would change the product.
        self.assertEqual(release.count("SWIFT_OPTIMIZATION_LEVEL"), 1)
        self.assertIn('SWIFT_OPTIMIZATION_LEVEL: "-O"\n', release)
        self.assertIn("SWIFT_COMPILATION_MODE: singlefile", release)
        self.assertNotIn("SWIFT_COMPILATION_MODE", debug)

    def test_timing_summary_parses_xcode_rows_without_visual_separator(self) -> None:
        log = """preamble
Build Timing Summary

PhaseScriptExecution (10 tasks) | 15.183 seconds
Copy (4 tasks) | 5.640 seconds

** BUILD SUCCEEDED **
"""
        self.assertEqual(
            build_economics.build_timing_summary(log),
            [
                {"task": "PhaseScriptExecution (10 tasks)", "seconds": 15.183},
                {"task": "Copy (4 tasks)", "seconds": 5.64},
            ],
        )

    def test_phase_parser_rejects_a_phase_without_dependency_analysis_policy(self) -> None:
        project = """targets:
  Fixture:
    type: application
    preBuildScripts:
      - name: Missing policy
        script: 'true'
schemes:
"""
        with self.assertRaisesRegex(ValueError, "Missing policy"):
            build_economics.project_script_phase_inventory(project)


if __name__ == "__main__":
    unittest.main()
