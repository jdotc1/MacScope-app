#!/usr/bin/env python3
"""Focused hermetic tests for the offline signing/install preflight."""

from __future__ import annotations

import json
import os
import plistlib
import subprocess
import tempfile
import unittest
import shutil
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "Scripts/smoke/signing_install_preflight.sh"


class SigningInstallPreflightTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name).resolve()
        self.app = self.root / "MacScope.app"
        contents = self.app / "Contents"
        contents.mkdir(parents=True)
        with (contents / "Info.plist").open("wb") as plist:
            plistlib.dump(
                {
                    "CFBundleIdentifier": "org.macscope.app",
                    "CFBundlePackageType": "APPL",
                    "CFBundleExecutable": "MacScope",
                },
                plist,
            )
        for relative in (
            "MacOS/MacScope",
            "MacOS/ShellBrokerLaunchAgent",
            "MacOS/SourceExecutionRunner",
            "Frameworks/libghostty-vt.dylib",
            "Resources/MacScopeBuildProvenance.json",
            "_CodeSignature/CodeResources",
            "XPCServices/AnalysisWorkerXPCService.xpc/Contents/Info.plist",
            "XPCServices/AIAgentWorkerXPCService.xpc/Contents/Info.plist",
            "XPCServices/NativeDecompilerXPCService.xpc/Contents/Info.plist",
            "XPCServices/ShellBrokerXPCService.xpc/Contents/Info.plist",
            "XPCServices/AnalysisWorkerXPCService.xpc/Contents/_CodeSignature/CodeResources",
            "XPCServices/AIAgentWorkerXPCService.xpc/Contents/_CodeSignature/CodeResources",
            "XPCServices/NativeDecompilerXPCService.xpc/Contents/_CodeSignature/CodeResources",
            "XPCServices/ShellBrokerXPCService.xpc/Contents/_CodeSignature/CodeResources",
        ):
            path = contents / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.touch()
        for service in ("AnalysisWorkerXPCService", "AIAgentWorkerXPCService", "NativeDecompilerXPCService", "ShellBrokerXPCService"):
            path = contents / "XPCServices" / f"{service}.xpc/Contents/MacOS/{service}"
            path.parent.mkdir(parents=True, exist_ok=True)
            path.touch()
        service_identifiers = {
            "AnalysisWorkerXPCService": "org.macscope.app.AnalysisWorker",
            "AIAgentWorkerXPCService": "org.macscope.app.AIAgentWorker",
            "NativeDecompilerXPCService": "org.macscope.app.NativeDecompiler",
            "ShellBrokerXPCService": "org.macscope.app.ShellBroker",
        }
        for service, identifier in service_identifiers.items():
            plist_path = contents / f"XPCServices/{service}.xpc/Contents/Info.plist"
            with plist_path.open("wb") as plist:
                plistlib.dump(
                    {
                        "CFBundleIdentifier": identifier,
                        "CFBundlePackageType": "XPC!",
                        "CFBundleExecutable": service,
                    },
                    plist,
                )
        (contents / "Resources/MacScopeBuildProvenance.json").write_text(
            json.dumps(
                {
                    "schema_version": 1,
                    "qualification_eligible": True,
                    "configuration": "Release",
                    "repository_clean": True,
                    "git_head_commit": "1" * 40,
                    "git_head_tree": "2" * 40,
                    "selected_build_inputs_sha256": "3" * 64,
                }
            ),
            encoding="utf-8",
        )
        self.tools = self.root / "tools"
        self.tools.mkdir()
        plutil = self.tools / "plutil"
        plutil.write_text(
            f"#!{sys.executable}\n"
            "import plistlib, sys\n"
            "assert len(sys.argv) == 5 and sys.argv[1] == '-extract' and sys.argv[3] == 'raw'\n"
            "with open(sys.argv[4], 'rb') as source: value = plistlib.load(source)\n"
            "print(value[sys.argv[2]])\n",
            encoding="utf-8",
        )
        plutil.chmod(0o755)
        self._tool("codesign", "exit 0\n")
        self._tool("lipo", "echo arm64\n")
        self._tool("otool", "echo '    minos 27.0'\n")
        self.policy = self.root / "policy.py"
        self.policy_log = self.root / "policy-arguments.json"
        self.policy.write_text(
            "import json, os, pathlib, sys\n"
            "pathlib.Path(os.environ['MACSCOPE_TEST_POLICY_LOG']).write_text("
            "json.dumps(sys.argv[1:]), encoding='utf-8')\n"
            "raise SystemExit(int(os.environ.get('MACSCOPE_TEST_POLICY_EXIT', '0')))\n",
            encoding="utf-8",
        )

    def tearDown(self) -> None:
        self.temp.cleanup()

    def _tool(self, name: str, body: str) -> None:
        path = self.tools / name
        path.write_text(f"#!/bin/sh\n{body}", encoding="utf-8")
        path.chmod(0o755)

    def environment(self, **overrides: str) -> dict[str, str]:
        env = {
            **os.environ,
            "MACSCOPE_PREFLIGHT_TEST_SEAMS": "1",
            "MACSCOPE_PREFLIGHT_PLUTIL": str(self.tools / "plutil"),
            "MACSCOPE_PREFLIGHT_CODESIGN": str(self.tools / "codesign"),
            "MACSCOPE_PREFLIGHT_LIPO": str(self.tools / "lipo"),
            "MACSCOPE_PREFLIGHT_OTOOL": str(self.tools / "otool"),
            "MACSCOPE_PREFLIGHT_PYTHON": "/usr/bin/python3",
            "MACSCOPE_PREFLIGHT_POLICY_CHECKER": str(self.policy),
            "MACSCOPE_TEST_POLICY_LOG": str(self.policy_log),
        }
        env.update(overrides)
        return env

    def run_preflight(
        self,
        *extra: str,
        environment_overrides: dict[str, str] | None = None,
    ) -> subprocess.CompletedProcess[str]:
        env = self.environment(**(environment_overrides or {}))
        return subprocess.run(
            [str(SCRIPT), "--app-bundle", str(self.app), "--destination", str(self.root / "Install.app"), *extra],
            text=True, capture_output=True, env=env, check=False,
        )

    def test_accepts_complete_offline_artifact(self) -> None:
        result = self.run_preflight()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("ready for a later", result.stdout)
        self.assertEqual(
            json.loads(self.policy_log.read_text(encoding="utf-8")),
            ["--app-bundle", str(self.app), "--configuration", "Release"],
        )

    def test_accepts_actual_release_producer_provenance(self) -> None:
        # Catch consumer-only schema requirements hidden by hand-authored fixtures.
        from Scripts.tests.test_release_build_provenance import (
            FixtureToolRunner, ReleaseRepositoryFixture, load_generator_module,
        )

        module = load_generator_module()
        fixture_root = self.root / "release-source"
        fixture_root.mkdir()
        fixture = ReleaseRepositoryFixture(fixture_root)
        payload = module.generate(fixture.arguments(module), tool_runner=FixtureToolRunner())
        (self.app / "Contents/Resources/MacScopeBuildProvenance.json").write_text(
            json.dumps(payload), encoding="utf-8"
        )
        result = self.run_preflight()
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_rejects_invalid_flat_source_identity_fields(self) -> None:
        provenance = self.app / "Contents/Resources/MacScopeBuildProvenance.json"
        valid = json.loads(provenance.read_text(encoding="utf-8"))
        for field in ("git_head_commit", "git_head_tree", "selected_build_inputs_sha256"):
            with self.subTest(field=field):
                provenance.write_text(json.dumps({**valid, field: "invalid"}), encoding="utf-8")
                result = self.run_preflight()
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("provenance is malformed or ineligible", result.stderr)

    def test_rejects_existing_install_destination(self) -> None:
        destination = self.root / "Install.app"
        destination.mkdir()
        result = self.run_preflight()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("refusing overwrite", result.stderr)

    def test_rejects_dangling_install_destination_symlink(self) -> None:
        destination = self.root / "Install.app"
        destination.symlink_to(self.root / "missing-install-target")
        result = self.run_preflight()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("refusing overwrite", result.stderr)

    def test_rejects_missing_embedded_service(self) -> None:
        (self.app / "Contents/XPCServices/NativeDecompilerXPCService.xpc").rename(self.root / "removed.xpc")
        result = self.run_preflight()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("NativeDecompilerXPCService.xpc", result.stderr)

    def test_rejects_unexpected_embedded_product_or_executable(self) -> None:
        unexpected_xpc = self.app / "Contents/XPCServices/PluginXPCService.xpc"
        unexpected_xpc.mkdir()
        result = self.run_preflight()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unexpected entry count", result.stderr)

        unexpected_xpc.rmdir()
        (self.app / "Contents/MacOS/OtherLaunchAgent").touch()
        result = self.run_preflight()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unexpected entry count", result.stderr)

        (self.app / "Contents/MacOS/OtherLaunchAgent").unlink()
        (self.app / "Contents/Frameworks/Unexpected.framework").touch()
        result = self.run_preflight()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Contents/Frameworks", result.stderr)

    def test_rejects_app_executable_metadata_substitution(self) -> None:
        self._tool(
            "plutil",
            'case "$2" in\n'
            '  CFBundleIdentifier) echo org.macscope.app ;;\n'
            '  CFBundlePackageType) echo APPL ;;\n'
            '  CFBundleExecutable) echo ShellBrokerLaunchAgent ;;\n'
            '  *) exit 1 ;;\n'
            'esac\n',
        )
        result = self.run_preflight()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("CFBundleExecutable", result.stderr)

    def test_rejects_symlink_substitution_and_missing_sealed_provenance(self) -> None:
        worker = (
            self.app
            / "Contents/XPCServices/AnalysisWorkerXPCService.xpc/Contents/MacOS/"
            "AnalysisWorkerXPCService"
        )
        target = self.root / "foreign-worker"
        target.touch()
        worker.unlink()
        worker.symlink_to(target)
        result = self.run_preflight()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("canonical single-link regular file", result.stderr)

        worker.unlink()
        worker.touch()
        provenance = self.app / "Contents/Resources/MacScopeBuildProvenance.json"
        provenance.unlink()
        result = self.run_preflight()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("MacScopeBuildProvenance.json", result.stderr)

    def test_rejects_mutated_code_resources_when_codesign_fails(self) -> None:
        (self.app / "Contents/_CodeSignature/CodeResources").write_bytes(b"mutated\n")
        self._tool("codesign", "exit 1\n")
        result = self.run_preflight()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("strict/deep code-sign verification failed", result.stderr)

    def test_rejects_debug_and_propagates_policy_failure_before_install(self) -> None:
        debug = self.run_preflight("--configuration", "Debug")
        self.assertEqual(debug.returncode, 2)
        self.assertIn("only the sealed Release", debug.stderr)

        rejected = self.run_preflight(
            environment_overrides={"MACSCOPE_TEST_POLICY_EXIT": "9"}
        )
        self.assertNotEqual(rejected.returncode, 0)
        self.assertIn("repository signing-policy checker rejected", rejected.stderr)
        self.assertFalse((self.root / "Install.app").exists())

    def test_rejects_tool_override_without_explicit_test_seam(self) -> None:
        environment = dict(os.environ)
        for name in (
            "MACSCOPE_PREFLIGHT_TEST_SEAMS",
            "MACSCOPE_PREFLIGHT_PLUTIL",
            "MACSCOPE_PREFLIGHT_CODESIGN",
            "MACSCOPE_PREFLIGHT_LIPO",
            "MACSCOPE_PREFLIGHT_OTOOL",
            "MACSCOPE_PREFLIGHT_PYTHON",
            "MACSCOPE_PREFLIGHT_POLICY_CHECKER",
        ):
            environment.pop(name, None)
        environment["MACSCOPE_PREFLIGHT_CODESIGN"] = str(self.tools / "codesign")
        result = subprocess.run(
            [
                str(SCRIPT),
                "--app-bundle",
                str(self.app),
                "--destination",
                str(self.root / "Install.app"),
            ],
            text=True,
            capture_output=True,
            env=environment,
            check=False,
        )
        self.assertEqual(result.returncode, 2)
        self.assertIn("tool overrides are test-only", result.stderr)

    def test_post_install_mode_passes_source_to_repository_checker(self) -> None:
        # The production contract requires both operands to be named MacScope.app.
        installed_named = self.root / "installed" / "MacScope.app"
        installed_named.parent.mkdir()
        shutil.copytree(self.app, installed_named)
        result = subprocess.run(
            [str(SCRIPT), "--source-app-bundle", str(self.app), "--app-bundle", str(installed_named), "--destination", str(installed_named)],
            text=True, capture_output=True,
            env=self.environment(), check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("source and installed", result.stdout)
        self.assertEqual(
            json.loads(self.policy_log.read_text(encoding="utf-8")),
            [
                "--source-app-bundle",
                str(self.app),
                "--app-bundle",
                str(installed_named),
                "--configuration",
                "Release",
            ],
        )

    def test_post_install_mode_rejects_parent_alias_to_same_bundle(self) -> None:
        alias_parent = self.root / "alias-parent"
        alias_parent.symlink_to(self.root, target_is_directory=True)
        aliased_source = alias_parent / "MacScope.app"

        result = subprocess.run(
            [
                str(SCRIPT),
                "--source-app-bundle",
                str(aliased_source),
                "--app-bundle",
                str(self.app),
            ],
            text=True,
            capture_output=True,
            env=self.environment(),
            check=False,
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("canonical non-symlink directory", result.stderr)
        self.assertFalse(self.policy_log.exists())

    def test_rejects_hardlinked_executable_and_malformed_provenance(self) -> None:
        executable = self.app / "Contents/MacOS/MacScope"
        os.link(executable, self.root / "second-link")
        hardlinked = self.run_preflight()
        self.assertNotEqual(hardlinked.returncode, 0)
        self.assertIn("single-link", hardlinked.stderr)
        (self.root / "second-link").unlink()

        provenance = self.app / "Contents/Resources/MacScopeBuildProvenance.json"
        provenance.write_text("{}", encoding="utf-8")
        malformed = self.run_preflight()
        self.assertNotEqual(malformed.returncode, 0)
        self.assertIn("provenance is malformed or ineligible", malformed.stderr)

    def test_bounds_local_tool_output_and_preserves_stdout_protocol(self) -> None:
        self._tool(
            "codesign",
            "/usr/bin/python3 -c 'import sys; sys.stderr.write(\"x\" * 70000)'\n",
        )
        result = self.run_preflight()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")
        self.assertLessEqual(len(result.stderr.encode("utf-8")), 1024)

    def test_source_contract_is_offline_and_uses_repository_signing_authority(self) -> None:
        source = SCRIPT.read_text(encoding="utf-8")
        self.assertIn("check_local_signing_policy.py", source)
        self.assertIn("--deep --strict", source)
        self.assertIn("TOOL_TIMEOUT_SECONDS", source)
        for forbidden in ("curl", "wget", "git clone", "xcodebuild"):
            self.assertNotIn(forbidden, source)


if __name__ == "__main__":
    unittest.main()
