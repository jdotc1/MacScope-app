#!/usr/bin/env python3

from __future__ import annotations

from pathlib import Path
import re
import unittest


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = REPOSITORY_ROOT / ".github" / "workflows" / "governance.yml"


class HostedGovernanceWorkflowTests(unittest.TestCase):
    def test_checkout_includes_content_verification_history(self) -> None:
        workflow = WORKFLOW.read_text(encoding="utf-8")
        checkout = re.search(
            r"(?ms)^      - uses: actions/checkout@v5\s*$"
            r"(?P<body>.*?)(?=^      - |\Z)",
            workflow,
        )
        self.assertIsNotNone(checkout, "hosted governance must check out repository source")
        self.assertRegex(
            checkout.group("body"),
            r"(?m)^        with:\s*$\n^          fetch-depth: 0\s*$",
            "Source provenance requires a full-history checkout",
        )

    def test_portable_python_client_step_runs_on_hosted_runner(self) -> None:
        workflow = WORKFLOW.read_text(encoding="utf-8")
        step = re.search(
            r"(?ms)^      - name: Run portable Python client tests\s*$"
            r"(?P<body>.*?)(?=^      - |^\S|\Z)",
            workflow,
        )
        self.assertIsNotNone(step, "portable MacScope/python/tests must have a visible CI step")
        self.assertRegex(
            step.group("body"),
            r"(?m)^          python3 Scripts/ci/run_python_client_tests\.py\s*$",
        )
        # MS-21: the same step also runs under the Python 3.9 floor (Apple's
        # /usr/bin/python3 on the self-hosted Mac), in this job.
        self.assertRegex(
            step.group("body"),
            r"(?m)^          /usr/bin/python3 Scripts/ci/run_python_client_tests\.py\s*$",
        )
        self.assertNotIn("actions/setup-python", workflow)
        self.assertEqual(workflow.count("runs-on:"), 1, "no parallel job for the 3.9 leg")
        self.assertNotIn("pip install", step.group("body"), "client lane stays dependency-free")
        self.assertTrue((REPOSITORY_ROOT / "Scripts/ci/run_python_client_tests.py").is_file())
        # The step belongs to the light self-hosted runner, never the Xcode runner.
        hosted_job = workflow[workflow.index("  hosted-governance:"):]
        self.assertIn("    runs-on: [self-hosted, macOS, ARM64, light]", hosted_job)
        self.assertNotIn("xcode-27", hosted_job)
        self.assertNotIn("ubuntu-latest", workflow)
        self.assertIn("Run portable Python client tests", hosted_job)

    def test_governance_runs_on_dispatch_and_nightly_only(self) -> None:
        # D12: no CI on pushes or pull requests; dispatch plus a nightly slot staggered after ci.yml's.
        workflow = WORKFLOW.read_text(encoding="utf-8")
        self.assertRegex(workflow, r"(?m)^  workflow_dispatch:\s*$")
        self.assertRegex(workflow, r'(?m)^    - cron: "45 7 \* \* \*"\s*$')
        self.assertNotRegex(workflow, r"(?m)^  push:")
        self.assertNotRegex(workflow, r"(?m)^  pull_request:")

    def test_self_hosted_job_has_fork_guard_and_local_lfs(self) -> None:
        workflow = WORKFLOW.read_text(encoding="utf-8")
        self.assertIn(
            "github.event.pull_request.head.repo.full_name == github.repository",
            workflow,
        )
        self.assertRegex(workflow, r"(?m)^          lfs: false\s*$")
        self.assertIn("git lfs checkout", workflow)
        self.assertNotIn("git lfs pull", workflow)
        self.assertNotIn("actions/cache", workflow)


if __name__ == "__main__":
    unittest.main()
