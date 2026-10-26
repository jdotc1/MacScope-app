#!/usr/bin/python3 -B
"""Subprocess contract for the canonical installed-acceptance CLI surface."""

from __future__ import annotations

from dataclasses import dataclass
import os
from pathlib import Path
import re
import subprocess
import unittest


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
SYSTEM_PYTHON = "/usr/bin/python3"
CLOSED_ENVIRONMENT = {
    "LANG": "C",
    "LC_ALL": "C",
    "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
    "PYTHONPATH": str(REPOSITORY_ROOT),
}


@dataclass(frozen=True)
class Surface:
    name: str
    path: Path
    flags: tuple[str, ...]
    help_succeeds: bool = True
    shell: bool = False

    @property
    def command(self) -> list[str]:
        if self.shell:
            return ["/bin/bash", str(self.path)]
        return [SYSTEM_PYTHON, "-B", str(self.path)]


RECONSTRUCTION = REPOSITORY_ROOT / "Scripts/reconstruction"
SURFACES = (
    Surface(
        "compiler",
        RECONSTRUCTION / "compile_installed_acceptance_gate_plan.py",
        (
            "--qualification-receipt",
            "--candidate-artifact-root",
            "--installation-pending-state",
            "--evidence-root",
            "--output",
        ),
    ),
    Surface(
        "transaction driver",
        RECONSTRUCTION / "run_installed_acceptance_transaction.py",
        (
            "--gate-plan-compiler",
            "--qualification-receipt",
            "--qualification-run-id",
            "--qualification-run-nonce",
            "--predecessor-observations-sha256",
            "--candidate-artifact-root",
            "--work-root",
            "--installed-app",
            "--begin-timeout-seconds",
            "--compiler-timeout-seconds",
            "--report-timeout-seconds",
            "--commit-timeout-seconds",
            "--rollback-timeout-seconds",
            "--result-output",
        ),
        help_succeeds=False,
    ),
    Surface(
        "wrapper",
        REPOSITORY_ROOT / "Scripts/install_local_private_build.sh",
        (
            "--mode",
            "--integration-ref",
            "--qualification-receipt",
            "--qualification-run-id",
            "--qualification-run-nonce",
            "--predecessor-observations-sha256",
            "--candidate-artifact-root",
            "--work-root",
            "--destination",
            "--signing",
            "--begin-timeout-seconds",
            "--compiler-timeout-seconds",
            "--report-timeout-seconds",
            "--commit-timeout-seconds",
            "--rollback-timeout-seconds",
        ),
        shell=True,
    ),
    Surface(
        "matrix adapter",
        RECONSTRUCTION / "emit_installed_incremental_xcuitest_evidence.py",
        (
            "--matrix-receipt",
            "--xcresult-semantic-manifest",
            "--network-artifact-root",
            "--qualification-run-id",
            "--qualification-run-nonce",
            "--predecessor-observations-sha256",
        ),
    ),
    Surface(
        "matrix runner",
        RECONSTRUCTION / "run_installed_task10_matrix.py",
        (
            "--candidate-identity",
            "--preparation-receipt",
            "--installed-app",
            "--xctestrun",
            "--test-bundle",
            "--ui-runner",
            "--xcresult",
            "--xcresult-semantic-manifest",
            "--receipt-output",
            "--network-artifact-root",
            "--qualification-run-id",
            "--qualification-run-nonce",
            "--predecessor-observations-sha256",
            "--developer-dir",
            "--timeout-seconds",
        ),
    ),
    Surface(
        "live evidence",
        RECONSTRUCTION / "emit_installed_live_evidence.py",
        (
            "--candidate-identity",
            "--source-app",
            "--installed-app",
            "--installation-pending-state",
            "--native-preparation-receipt",
            "--matrix-receipt",
            "--xcresult-semantic-manifest",
            "--network-artifact-root",
            "--qualification-run-id",
            "--qualification-run-nonce",
            "--evidence-root",
            "--live-gates-timeout-seconds",
        ),
    ),
    Surface(
        "live runner",
        RECONSTRUCTION / "run_ws24_installed_live_gates.py",
        (),
        help_succeeds=False,
    ),
    Surface(
        "WS24 bridge",
        REPOSITORY_ROOT / "Scripts/ws24_emit_installed_qualification_report.py",
        (
            "--installed-app",
            "--source-app",
            "--evidence-json",
            "--candidate-identity",
            "--output",
            "--expected-source-commit",
            "--qualification-run-id",
            "--qualification-run-nonce",
            "--installation-pending-state",
            "--full-surface-report",
            "--legacy-grid-report",
            "--cli-gui-operability-report",
            "--mcp-operability-report",
            "--native-xpc-execution-report",
            "--acceptance-gate-output",
            "--generated-at-unix-ms",
            "--xcode-developer-dir",
        ),
    ),
    Surface(
        "native gate",
        REPOSITORY_ROOT
        / "Scripts/native-decompiler-xpc/run_installed_native_xpc_gate.py",
        (
            "--installed-app",
            "--candidate-identity",
            "--preparation-receipt",
            "--artifact-root",
            "--qualification-run-id",
            "--qualification-run-nonce",
            "--predecessor-observations-sha256",
            "--phase-timeout-seconds",
        ),
    ),
    Surface(
        "final validator",
        RECONSTRUCTION / "validate_final_local_candidate.py",
        (
            "--transaction-result",
            "--integration-ref",
            "--qualification-receipt",
            "--candidate-artifact-root",
            "--output",
        ),
    ),
)


class InstalledAcceptanceCLISurfaceTests(unittest.TestCase):
    def invoke(self, surface: Surface, *arguments: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [*surface.command, *arguments],
            cwd=REPOSITORY_ROOT,
            env=CLOSED_ENVIRONMENT,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            check=False,
        )

    def test_help_is_stream_clean_and_lists_flags_in_frozen_order(self) -> None:
        for surface in SURFACES:
            with self.subTest(surface=surface.name):
                result = self.invoke(surface, "--help")
                self.assertNotIn("Traceback", result.stderr)
                if not surface.help_succeeds:
                    self.assertNotEqual(result.returncode, 0)
                    self.assertEqual(result.stdout, "")
                    self.assertNotEqual(result.stderr, "")
                    continue
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stderr, "")
                self.assertTrue(result.stdout.lower().startswith("usage:"))
                # Match whole flags: the wrapper's ordinary-mode usage also
                # lists --signing-receipt (76b5de75b) ahead of --signing.
                offsets = [
                    re.search(r"(?<![\w-])" + re.escape(flag) + r"(?![\w-])", result.stdout).start()
                    for flag in surface.flags
                ]
                self.assertEqual(offsets, sorted(offsets))

    def test_legacy_argv_fails_with_stderr_only(self) -> None:
        legacy_flags = (
            "--installation-operation-report",
            "--installation-source-equality-report",
            "--installation-execution-report",
        )
        for index, surface in enumerate(SURFACES):
            with self.subTest(surface=surface.name):
                result = self.invoke(surface, legacy_flags[index % len(legacy_flags)], "/tmp/x")
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, "")
                self.assertNotEqual(result.stderr, "")
                self.assertNotIn("Traceback", result.stderr)


if __name__ == "__main__":
    unittest.main()
