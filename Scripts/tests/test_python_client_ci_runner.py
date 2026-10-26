#!/usr/bin/env python3

from __future__ import annotations

import importlib.util
from pathlib import Path
import subprocess
import sys
import unittest


ROOT = Path(__file__).resolve().parents[2]
RUNNER = ROOT / "Scripts" / "ci" / "run_python_client_tests.py"
SPEC = importlib.util.spec_from_file_location("run_python_client_tests", RUNNER)
assert SPEC is not None and SPEC.loader is not None
module = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(module)


class PythonClientCIRunnerTests(unittest.TestCase):
    def test_native_suite_is_excluded_with_a_concrete_reason(self) -> None:
        discovery = module.discover_modules()
        self.assertIn("test_macscope.py", dict(discovery.native_only_modules))
        self.assertNotIn("test_macscope.py", discovery.selected_modules)
        for name, reason in module.NATIVE_ONLY_REASONS.items():
            with self.subTest(module=name):
                self.assertTrue((module.TESTS / name).is_file())
                self.assertGreaterEqual(len(reason.split()), 6)

    def test_portable_modules_are_selected_by_default(self) -> None:
        selected = module.discover_modules().selected_modules
        for name in (
            "test_deadlines.py",
            "test_explicit_null.py",
            "test_native_binding.py",
            "test_portable_client.py",
            "test_protocol_errors.py",
            "test_teardown.py",
        ):
            with self.subTest(module=name):
                self.assertIn(name, selected)

    def test_stale_denylist_entry_and_empty_selection_are_rejected(self) -> None:
        with self.assertRaises(module.ClientTestDiscoveryError):
            module.classify_modules(["test_a.py"], {"test_gone.py": "reason"})
        with self.assertRaises(module.ClientTestDiscoveryError):
            module.classify_modules(["test_native.py"], {"test_native.py": "reason"})
        discovery = module.classify_modules(["test_b.py", "test_a.py", "test_n.py"], {"test_n.py": "r"})
        self.assertEqual(discovery.selected_modules, ("test_a.py", "test_b.py"))

    def test_floor_compile_covers_build_phases_and_lldb_extractors(self) -> None:
        names = [name for name, _ in module.floor_compile_units()]
        self.assertIn("Scripts/build_phase_stamp.py", names)
        self.assertIn("Scripts/check_local_signing_policy.py", names)
        self.assertEqual(sum(name.endswith(":extractorSource") for name in names), 2)
        self.assertEqual(module.compile_floor_sources(module.floor_compile_units()), [])

    def test_floor_compile_reports_syntax_the_interpreter_rejects(self) -> None:
        failures = module.compile_floor_sources([("bad.py", "def f(:\n    pass\n")])
        self.assertEqual(len(failures), 1)
        self.assertTrue(failures[0].startswith("bad.py:1:"))

    def test_runner_passes_end_to_end_without_third_party_packages(self) -> None:
        completed = subprocess.run(
            [sys.executable, "-I", str(RUNNER)],
            cwd=ROOT,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            universal_newlines=True,
            timeout=120,
        )
        self.assertEqual(completed.returncode, 0, completed.stdout)
        self.assertIn("excluded native-only test_macscope.py", completed.stdout)
        self.assertRegex(completed.stdout, r"ran=[1-9]\d* failures=0 errors=0 skipped=0")


if __name__ == "__main__":
    unittest.main()
