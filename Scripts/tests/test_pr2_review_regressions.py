"""Item 334 source-proposed regressions; not executed in the review.

Copy into Scripts/tests/ in the pinned checkout before an authorized run.
No native runner, compiler, build, or research evidence harness is launched.
"""
from pathlib import Path
import importlib.util
import os
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[2]
ROOT_NAMES = (
    "MACSCOPE_CI_QUALIFICATION_ROOT",
    "MACSCOPE_DEPENDENCY_CACHE_ROOT",
    "MACSCOPE_PATTERN_ADAPTER_ROOT",
    "MACSCOPE_PATTERN_ADAPTER_RECEIPT",
)


def guard_module():
    spec = importlib.util.spec_from_file_location(
        "check_local_signing_policy", ROOT / "Scripts/check_local_signing_policy.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class PR2RunnerRootGuardTests(unittest.TestCase):
    def setUp(self):
        self.guard = guard_module()
        self.workflow = (ROOT / ".github/workflows/ci.yml").read_text()

    def test_rejects_quoted_step_environment_overrides(self):
        marker = "      - name: Build and test\n        env:\n"
        self.assertEqual(self.workflow.count(marker), 1)
        for name in ROOT_NAMES:
            for quote in ("'", '"'):
                with self.subTest(name=name, quote=quote):
                    altered = self.workflow.replace(
                        marker, marker + "          " + quote + name + quote + ": /tmp/redirected\n", 1)
                    self.assertFalse(self.guard.validate_ci_runner_work_roots(altered))

    def test_rejects_later_quoted_shell_exports(self):
        marker = '} >> "$GITHUB_ENV"'
        self.assertEqual(self.workflow.count(marker), 1)
        for name in ROOT_NAMES:
            with self.subTest(name=name):
                altered = self.workflow.replace(
                    marker, marker + '\n          echo "' + name + '"=/tmp/redirected >> "$GITHUB_ENV"', 1)
                self.assertFalse(self.guard.validate_ci_runner_work_roots(altered))

    def test_rejects_skipped_root_export_step(self):
        marker = "      - name: Clear stale sparse checkout from the reused workspace\n"
        self.assertEqual(self.workflow.count(marker), 1)
        altered = self.workflow.replace(marker, marker + "        if: false\n", 1)
        self.assertFalse(self.guard.validate_ci_runner_work_roots(altered))

    def test_rejects_inert_shell_root_export_block(self):
        marker = '          : "${MACSCOPE_WORK_ROOT:?set MACSCOPE_WORK_ROOT in the runner .env file}"'
        altered = self.workflow.replace(marker, "          if false; then\n" + marker, 1)
        altered = altered.replace('          } >> "$GITHUB_ENV"', '          } >> "$GITHUB_ENV"\n          fi', 1)
        self.assertFalse(self.guard.validate_ci_runner_work_roots(altered))

    def test_retains_literal_workflow_positive_control(self):
        self.assertTrue(self.guard.validate_ci_runner_work_roots(self.workflow))

    def test_retains_rejection_of_unquoted_override(self):
        marker = "      - name: Build and test\n        env:\n"
        altered = self.workflow.replace(marker, marker + "          MACSCOPE_CI_QUALIFICATION_ROOT: /tmp/redirected\n", 1)
        self.assertFalse(self.guard.validate_ci_runner_work_roots(altered))


class PR2ExplicitStationPoolTests(unittest.TestCase):
    def invoke(self, pool):
        environment = dict(os.environ, MACSCOPE_WORK_ROOT="/tmp/item334-work",
                           MACSCOPE_STATIONS=pool)
        return subprocess.run(
            ["/bin/bash", str(ROOT / "Scripts/station.sh"), "list"],
            env=environment, capture_output=True, text=True, timeout=10)

    def test_explicit_pool_refuses_detached_whitespace_path_fragment(self):
        result = self.invoke("S1=/Volumes/Owner Work")
        self.assertEqual(result.returncode, 2)
        self.assertEqual(result.stdout, "")
        self.assertIn("station pool requires", result.stderr)

    def test_explicit_pool_refuses_tab_path_fragment(self):
        result = self.invoke("S1=/Volumes/Owner\tWork")
        self.assertEqual(result.returncode, 2)
        self.assertEqual(result.stdout, "")
        self.assertIn("station pool requires", result.stderr)

    def test_explicit_pool_keeps_two_well_formed_entries(self):
        result = self.invoke("S1=/__item334_missing_a S2=/__item334_missing_b")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("/__item334_missing_a", result.stdout)
        self.assertIn("/__item334_missing_b", result.stdout)


if __name__ == "__main__":
    unittest.main()
