#!/usr/bin/env python3

from __future__ import annotations

import importlib.util
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
RUNNER = ROOT / "Scripts" / "ci" / "run_hosted_governance.py"
SPEC = importlib.util.spec_from_file_location("run_hosted_governance", RUNNER)
assert SPEC is not None and SPEC.loader is not None
module = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(module)


class HostedGovernanceDenylistTests(unittest.TestCase):
    def test_every_exclusion_has_a_concrete_reviewed_host_boundary(self) -> None:
        self.assertEqual(set(module.MACOS_ONLY_REASONS), set(module.MACOS_ONLY))
        for name, reason in module.MACOS_ONLY_REASONS.items():
            with self.subTest(module=name):
                self.assertTrue((ROOT / "Scripts" / "tests" / name).is_file())
                self.assertGreaterEqual(len(reason.split()), 6)
                self.assertNotIn("macOS-only tooling", reason)

    def test_native_install_destination_and_tool_execution_stay_mac_only(self) -> None:
        self.assertIn("test_install_local_private_build.py", module.MACOS_ONLY)
        self.assertIn("test_xcodegen_materialization.py", module.MACOS_ONLY)

    def test_fully_mocked_host_suites_run_in_the_hosted_lane(self) -> None:
        for name in (
            "test_debugger_fixture_tool.py",
            "test_ws24_emit_installed_qualification_report.py",
        ):
            with self.subTest(module=name):
                self.assertNotIn(name, module.MACOS_ONLY)

    def test_signing_integration_stays_mac_only_while_declaration_parity_is_hosted(
        self,
    ) -> None:
        self.assertIn("test_local_signing_policy.py", module.MACOS_ONLY)
        self.assertNotIn("test_signing_identity_declaration.py", module.MACOS_ONLY)


if __name__ == "__main__":
    unittest.main()
