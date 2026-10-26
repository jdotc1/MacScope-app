#!/usr/bin/env python3
"""Focused contract tests for the installed CLI/GUI smoke harness."""

from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import unittest


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "Scripts/smoke/cli_gui_operability_smoke.sh"
CANDIDATE = "a" * 40
TREE = "c" * 40


def canonical_json(value: object) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":")).encode("utf-8")


class CLIGUIOperabilitySmokeTests(unittest.TestCase):
    def run_script(
        self,
        *args: str,
        environment: dict[str, str] | None = None,
        timeout: float = 10.0,
    ) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [str(SCRIPT), *args],
            cwd=ROOT,
            text=True,
            capture_output=True,
            timeout=timeout,
            check=False,
            env=environment,
        )

    def test_invalid_top_level_provenance_is_rejected_before_launch(self) -> None:
        invalid_fields = (
            ("schema_version", None),
            ("schema_version", True),
            ("schema_version", 1.0),
            ("schema_version", 2),
            ("git_head_commit", None),
            ("git_head_commit", "b" * 40),
            ("git_head_tree", None),
            ("git_head_tree", "c" * 39),
            ("git_head_tree", int("1" * 40)),
            ("selected_build_inputs_sha256", None),
            ("selected_build_inputs_sha256", "d" * 63),
            ("selected_build_inputs_sha256", int("1" * 64)),
            ("qualification_eligible", False),
            ("repository_clean", False),
            ("configuration", "Debug"),
        )
        for field, value in invalid_fields:
            with self.subTest(field=field, value=value):
                with self.fake_app(marker=True) as fixture:
                    payload = json.loads(fixture.provenance.read_text(encoding="utf-8"))
                    if value is None:
                        payload.pop(field)
                    else:
                        payload[field] = value
                    # A fabricated nested identity must never rescue invalid real fields.
                    payload["source_identity"] = {"kind": "fixture"}
                    fixture.provenance.write_text(json.dumps(payload), encoding="utf-8")
                    result = self.run_script(
                        "--app", str(fixture.app), "--mode", "cli",
                        "--candidate-commit", CANDIDATE,
                    )
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn("eligible sealed Release", result.stderr)
                    self.assertFalse(fixture.marker.exists())

    def test_preflight_is_deterministic_and_does_not_need_an_app(self) -> None:
        first = self.run_script("--preflight")
        second = self.run_script("--preflight")
        self.assertEqual(first.returncode, 0, first.stderr)
        self.assertEqual(first.stdout, second.stdout)
        self.assertEqual(first.stderr, "")
        self.assertIn("repository preflight", first.stdout)

    def test_help_and_unknown_option_preserve_the_cli_surface(self) -> None:
        result = self.run_script("--help")
        self.assertEqual(result.returncode, 0)
        for option in (
            "--mode",
            "--app",
            "--binary",
            "--candidate-commit",
            "--timeout-seconds",
            "--output",
        ):
            self.assertIn(option, result.stdout)
        unknown = self.run_script("--not-a-real-option")
        self.assertNotEqual(unknown.returncode, 0)
        self.assertIn("unrecognized arguments", unknown.stderr)

    def test_installed_mode_rejects_missing_symlink_and_parent_alias(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            missing = root / "Missing.app"
            result = self.run_script(
                "--app", str(missing), "--mode", "gui",
                "--candidate-commit", CANDIDATE,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("unavailable", result.stderr)

            target = root / "MacScope.app"
            target.mkdir()
            link = root / "Link.app"
            link.symlink_to(target, target_is_directory=True)
            result = self.run_script(
                "--app", str(link), "--mode", "gui",
                "--candidate-commit", CANDIDATE,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("canonical", result.stderr)

            alias = root / "alias"
            alias.symlink_to(root, target_is_directory=True)
            result = self.run_script(
                "--app",
                str(alias / "MacScope.app"),
                "--mode",
                "gui",
                "--candidate-commit",
                CANDIDATE,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("canonical", result.stderr)

    def test_cli_emits_only_harness_protocol_and_accepts_one_json_value(self) -> None:
        with self.fake_app() as fixture:
            result = self.run_script(
                "--app",
                str(fixture.app),
                "--mode",
                "cli",
                "--timeout-seconds",
                "2",
                "--candidate-commit",
                CANDIDATE,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stderr, "")
            self.assertEqual(
                result.stdout,
                "PASS: installed cli launch/readiness probe\n",
            )

    def test_gui_requires_observability_not_process_presence(self) -> None:
        with self.fake_app() as fixture:
            environment = self._test_environment(observable=False)
            result = self.run_script(
                "--app",
                str(fixture.app),
                "--mode",
                "gui",
                "--timeout-seconds",
                "1",
                "--candidate-commit",
                CANDIDATE,
                environment=environment,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("process remained present", result.stderr)
            self.assertEqual(result.stdout, "")

            environment = self._test_environment(observable=True)
            passed = self.run_script(
                "--app",
                str(fixture.app),
                "--mode",
                "gui",
                "--timeout-seconds",
                "2",
                "--candidate-commit",
                CANDIDATE,
                environment=environment,
            )
            self.assertEqual(passed.returncode, 0, passed.stderr)
            self.assertEqual(
                passed.stdout,
                "PASS: installed gui launch/readiness probe\n",
            )

    def test_cli_bounds_stdout_and_retires_the_owned_process(self) -> None:
        with self.fake_app() as fixture:
            fixture.executable.write_text(
                "#!/bin/bash\n"
                "trap 'exit 0' TERM INT\n"
                "if [[ ${1:-} == --run-script ]]; then\n"
                "  /usr/bin/python3 -c 'import sys; sys.stdout.write(\"x\" * 70000)'\n"
                "  while :; do sleep 1; done\n"
                "fi\n"
                "while :; do sleep 1; done\n",
                encoding="utf-8",
            )
            fixture.executable.chmod(0o755)
            result = self.run_script(
                "--app",
                str(fixture.app),
                "--mode",
                "cli",
                "--timeout-seconds",
                "2",
                "--candidate-commit",
                CANDIDATE,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("stdout exceeded", result.stderr)
            self.assertLessEqual(len(result.stderr.encode("utf-8")), 1024)

    def test_bridge_report_is_exact_canonical_create_only_and_candidate_bound(self) -> None:
        with self.fake_app() as fixture:
            report = fixture.root / "cli-gui-report.json"
            authority_path, authority = fixture.authority()
            environment = self._test_environment(observable=True)
            environment["MACSCOPE_OPERABILITY_TEST_AUTHORITY"] = str(authority_path)
            result = self.run_script(
                "--app",
                str(fixture.app),
                "--mode",
                "both",
                "--binary",
                "/usr/bin/true",
                "--timeout-seconds",
                "2",
                "--candidate-commit",
                CANDIDATE,
                "--output",
                str(report),
                environment=environment,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            payload = report.read_bytes()
            document = json.loads(payload)
            self.assertEqual(payload, canonical_json(document))
            self.assertEqual(report.stat().st_nlink, 1)
            self.assertEqual(
                set(document),
                {"authority", "probeResults", "reportKind", "schemaVersion", "status"},
            )
            self.assertEqual(document["authority"], authority)
            self.assertEqual(document["probeResults"], {"cli": True, "gui": True})
            self.assertEqual(document["reportKind"], "macscope-cli-gui-operability-report-v1")
            self.assertEqual(document["status"], "passed")

            repeated = self.run_script(
                "--app",
                str(fixture.app),
                "--mode",
                "both",
                "--candidate-commit",
                CANDIDATE,
                "--output",
                str(report),
                environment=environment,
            )
            self.assertNotEqual(repeated.returncode, 0)
            self.assertIn("create-only", repeated.stderr)

    def test_stale_or_synthetic_authority_is_rejected_before_launch(self) -> None:
        with self.fake_app(marker=True) as fixture:
            authority_path, authority = fixture.authority()
            authority["installedExecutableSHA256"] = "0" * 64
            authority_path.write_bytes(canonical_json(authority))
            environment = self._test_environment(observable=True)
            environment["MACSCOPE_OPERABILITY_TEST_AUTHORITY"] = str(authority_path)
            result = self.run_script(
                "--app",
                str(fixture.app),
                "--mode",
                "both",
                "--candidate-commit",
                CANDIDATE,
                "--output",
                str(fixture.root / "report.json"),
                environment=environment,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("stale, synthetic", result.stderr)
            self.assertFalse(fixture.marker.exists())

            no_seam = dict(os.environ)
            no_seam["MACSCOPE_OPERABILITY_TEST_AUTHORITY"] = str(authority_path)
            no_seam.pop("MACSCOPE_OPERABILITY_TEST_SEAMS", None)
            rejected = self.run_script("--preflight", environment=no_seam)
            self.assertNotEqual(rejected.returncode, 0)
            self.assertIn("explicit test seam", rejected.stderr)

    def test_stale_provenance_and_hardlinked_executable_are_rejected(self) -> None:
        with self.fake_app() as fixture:
            payload = json.loads(fixture.provenance.read_text(encoding="utf-8"))
            payload["git_head_commit"] = "b" * 40
            fixture.provenance.write_text(json.dumps(payload), encoding="utf-8")
            stale = self.run_script(
                "--app",
                str(fixture.app),
                "--mode",
                "cli",
                "--candidate-commit",
                CANDIDATE,
            )
            self.assertNotEqual(stale.returncode, 0)
            self.assertIn("eligible sealed Release", stale.stderr)

        with self.fake_app() as fixture:
            os.link(fixture.executable, fixture.root / "second-link")
            linked = self.run_script(
                "--app",
                str(fixture.app),
                "--mode",
                "cli",
                "--candidate-commit",
                CANDIDATE,
            )
            self.assertNotEqual(linked.returncode, 0)
            self.assertIn("single-link", linked.stderr)

    def test_harness_has_no_build_online_or_name_sweep_surface(self) -> None:
        source = SCRIPT.read_text(encoding="utf-8")
        self.assertIn("/usr/bin/open", source)
        self.assertIn("finishedLaunching", source)
        self.assertIn("window_count", source)
        self.assertIn("start_new_session=True", source)
        self.assertIn("MAX_CAPTURE_BYTES", source)
        for forbidden in ("xcodebuild", "curl", "git clone", "pkill", "killall"):
            self.assertNotIn(forbidden, source)

    @staticmethod
    def _test_environment(*, observable: bool) -> dict[str, str]:
        environment = dict(os.environ)
        environment["MACSCOPE_OPERABILITY_TEST_SEAMS"] = "1"
        environment["MACSCOPE_OPERABILITY_TEST_GUI_DIRECT"] = "1"
        if observable:
            environment["MACSCOPE_OPERABILITY_TEST_GUI_OBSERVABLE"] = "1"
        else:
            environment.pop("MACSCOPE_OPERABILITY_TEST_GUI_OBSERVABLE", None)
        return environment

    def fake_app(self, *, marker: bool = False) -> "FakeAppContext":
        return FakeAppContext(marker=marker)


class FakeAppContext:
    def __init__(self, *, marker: bool) -> None:
        self.directory = tempfile.TemporaryDirectory()
        self.root = Path(self.directory.name).resolve()
        self.app = self.root / "MacScope.app"
        self.executable = self.app / "Contents/MacOS/MacScope"
        self.provenance = self.app / "Contents/Resources/MacScopeBuildProvenance.json"
        self.marker = self.root / "launched"
        self.executable.parent.mkdir(parents=True)
        marker_line = f"touch {self.marker!s}\n" if marker else ""
        self.executable.write_text(
            "#!/bin/bash\n"
            "set -u\n"
            + marker_line
            + "if [[ ${1:-} == --run-script ]]; then\n"
            "  test -s \"$2\" || exit 1\n"
            "  printf '%s\\n' '[{\"command\":\"commands\"}]'\n"
            "  exit 0\n"
            "fi\n"
            "trap 'exit 0' TERM INT\n"
            "while :; do sleep 1; done\n",
            encoding="utf-8",
        )
        self.executable.chmod(0o755)
        self.provenance.parent.mkdir(parents=True)
        self.provenance.write_text(
            json.dumps(
                {
                    "schema_version": 1,
                    "qualification_eligible": True,
                    "configuration": "Release",
                    "repository_clean": True,
                    "git_head_commit": CANDIDATE,
                    "git_head_tree": TREE,
                    "selected_build_inputs_sha256": "d" * 64,
                }
            ),
            encoding="utf-8",
        )

    def __enter__(self) -> "FakeAppContext":
        return self

    def __exit__(self, *_: object) -> None:
        self.directory.cleanup()

    def authority(self) -> tuple[Path, dict[str, object]]:
        executable_digest = hashlib.sha256(self.executable.read_bytes()).hexdigest()
        provenance_digest = hashlib.sha256(self.provenance.read_bytes()).hexdigest()
        authority: dict[str, object] = {
            "applicationExecutableSHA256": executable_digest,
            "buildProvenanceSHA256": provenance_digest,
            "candidateFileSHA256": "1" * 64,
            "candidateIdentitySHA256": "2" * 64,
            "destinationIdentitySHA256": "3" * 64,
            "executionIdentitySHA256": "4" * 64,
            "exposedAtUnixNanoseconds": time.time_ns() - 1_000_000,
            "forcedLegacyGridReportSHA256": "5" * 64,
            "fullSurfaceReportSHA256": "6" * 64,
            "installedExecutableSHA256": executable_digest,
            "installationPendingStateSHA256": "7" * 64,
            "nativeLiveXPCReportSHA256": "8" * 64,
            "predecessorObservationsSHA256": "9" * 64,
            "qualificationRunID": "focused-operability-test",
            "shellBrokerExecutableSHA256": "a" * 64,
            "shellBrokerInfoPlistSHA256": "b" * 64,
            "sourceCommit": CANDIDATE,
            "sourceEqualitySHA256": "c" * 64,
            "sourceTree": TREE,
            "transactionID": "focused-transaction",
        }
        path = self.root / "authority.json"
        path.write_bytes(canonical_json(authority))
        return path, authority


if __name__ == "__main__":
    unittest.main()
