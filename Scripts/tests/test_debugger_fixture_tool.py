#!/usr/bin/env python3

from __future__ import annotations

import importlib.util
import json
import os
import plistlib
import subprocess
import sys
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from io import StringIO
from pathlib import Path


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
FIXTURE_ROOT = REPOSITORY_ROOT / "Scripts" / "debugger-fixture"
FIXTURE_TOOL = FIXTURE_ROOT / "fixture_tool.py"


def load_fixture_tool():
    specification = importlib.util.spec_from_file_location("fixture_tool", FIXTURE_TOOL)
    assert specification is not None and specification.loader is not None
    module = importlib.util.module_from_spec(specification)
    sys.modules[specification.name] = module
    specification.loader.exec_module(module)
    return module


class RecordingRunner:
    def __init__(self) -> None:
        self.calls = []
        self.responses = {}

    def __call__(self, command, environment=None):
        self.calls.append((tuple(command), dict(environment or {})))
        response = self.responses.get(tuple(command))
        if response is not None:
            return response
        return subprocess.CompletedProcess(command, 0, "", "")


class ToolchainRunner(RecordingRunner):
    def __call__(self, command, environment=None):
        self.calls.append((tuple(command), dict(environment or {})))
        rendered = tuple(command)
        if rendered[-1:] == ("-version",) and "xcodebuild" in rendered[0]:
            return subprocess.CompletedProcess(command, 0, "Xcode 27.1\nBuild version 18A1\n", "")
        if rendered[:3] == ("/usr/bin/xcrun", "--sdk", "macosx"):
            if rendered[-1] == "--show-sdk-path":
                return subprocess.CompletedProcess(command, 0, "/Selected/SDKs/MacOSX27.1.sdk\n", "")
            if rendered[-1] == "--show-sdk-version":
                return subprocess.CompletedProcess(command, 0, "27.1\n", "")
        if rendered[:2] == ("/usr/bin/xcrun", "--find"):
            return subprocess.CompletedProcess(command, 0, "/Selected/usr/bin/%s\n" % rendered[-1], "")
        if rendered[:2] == ("/usr/bin/xcrun", "--version"):
            return subprocess.CompletedProcess(command, 0, "%s version 27.1\n" % rendered[-1], "")
        raise AssertionError("unexpected toolchain command: %r" % (rendered,))


class ArtifactRunner:
    SIGNER = "Apple Development: MacScope Developer (CERT000000)"
    TEAM = "TEAM000000"

    def __init__(self, *, signer=None, team=None, uuid_mismatch=False, preferred_mismatch=False):
        self.signer = signer or self.SIGNER
        self.team = team or self.TEAM
        self.uuid_mismatch = uuid_mismatch
        self.preferred_mismatch = preferred_mismatch
        self.calls = []

    @staticmethod
    def role(path):
        if "Runtime.framework" in path:
            return "framework"
        if path.endswith("MacScopeDebuggerHelper"):
            return "helper"
        return "app"

    def __call__(self, command, environment=None):
        self.calls.append(tuple(command))
        joined = " ".join(str(value) for value in command)
        path = str(command[-1])
        role = self.role(path)
        identifiers = {
            "app": "org.macscope.app.debugger-fixture",
            "framework": "org.macscope.app.debugger-fixture.runtime",
            "helper": "org.macscope.app.debugger-fixture.helper",
        }
        uuids = {
            "app": "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
            "framework": "11111111-2222-3333-4444-555555555555",
            "helper": "99999999-8888-7777-6666-555555555555",
        }
        if command[:4] == ["/usr/bin/security", "find-identity", "-v", "-p"]:
            output = '  1) %s "%s"\n     1 valid identities found\n' % ("A" * 40, self.signer)
            return subprocess.CompletedProcess(command, 0, output, "")
        if command[0] == "/usr/bin/lipo":
            return subprocess.CompletedProcess(command, 0, "arm64\n", "")
        if "vtool" in command:
            return subprocess.CompletedProcess(command, 0, "platform MACOS\nminos 27.0\nsdk 27.0\n", "")
        if command[0] == "/usr/bin/codesign" and "--verify" in command:
            return subprocess.CompletedProcess(command, 0, "", "")
        if command[0] == "/usr/bin/codesign" and "--verbose=4" in command:
            details = (
                "Identifier=%s\nCodeDirectory flags=0x10000(runtime)\n"
                "CDHash=0123456789abcdef0123456789abcdef01234567\n"
                "Authority=%s\nTeamIdentifier=%s\n"
            ) % (identifiers[role], self.signer, self.team)
            return subprocess.CompletedProcess(command, 0, "", details)
        if command[0] == "/usr/bin/codesign" and "-r-" in command:
            requirement = (
                'designated => identifier "%s" and anchor apple generic and '
                'certificate leaf[subject.CN] = "%s" and '
                'certificate 1[field.1.2.840.113635.100.6.2.1] exists\n'
            ) % (identifiers[role], self.signer)
            return subprocess.CompletedProcess(command, 0, "", requirement)
        if command[0] == "/usr/bin/codesign" and "--entitlements" in command:
            entitlements = {} if role == "framework" else {"com.apple.security.get-task-allow": True}
            return subprocess.CompletedProcess(command, 0, plistlib.dumps(entitlements).decode(), "")
        if "dwarfdump" in command:
            uuid = uuids[role]
            if self.uuid_mismatch and ".dSYM" in path and role == "framework":
                uuid = "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF"
            return subprocess.CompletedProcess(command, 0, "UUID: %s (arm64) %s\n" % (uuid, path), "")
        if "nm" in command:
            preferred = "0000000700000000"
            if self.preferred_mismatch and role == "framework":
                preferred = "0000000700000010"
            return subprocess.CompletedProcess(
                command,
                0,
                "%s (__MACSCOPE,__probe) external _macscope_fixture_preferred_probe\n" % preferred,
                "",
            )
        raise AssertionError("unexpected verification command: %s" % joined)


def create_artifact_topology(root):
    paths = [
        "MacScopeDebuggerFixture.app/Contents/Info.plist",
        "MacScopeDebuggerFixture.app/Contents/MacOS/MacScopeDebuggerFixture",
        "MacScopeDebuggerFixture.app/Contents/Frameworks/MacScopeDebuggerFixtureRuntime.framework/Info.plist",
        "MacScopeDebuggerFixture.app/Contents/Frameworks/MacScopeDebuggerFixtureRuntime.framework/MacScopeDebuggerFixtureRuntime",
        "MacScopeDebuggerFixture.app/Contents/Helpers/MacScopeDebuggerHelper",
        "MacScopeDebuggerFixture.app.dSYM/Contents/Resources/DWARF/MacScopeDebuggerFixture",
        "MacScopeDebuggerFixtureRuntime.framework.dSYM/Contents/Resources/DWARF/MacScopeDebuggerFixtureRuntime",
        "MacScopeDebuggerHelper.dSYM/Contents/Resources/DWARF/MacScopeDebuggerHelper",
    ]
    for relative in paths:
        path = root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        if relative.endswith("Contents/Info.plist") and "Runtime.framework" not in relative:
            path.write_bytes((FIXTURE_ROOT / "Resources" / "AppInfo.plist").read_bytes())
        elif relative.endswith("Runtime.framework/Info.plist"):
            path.write_bytes((FIXTURE_ROOT / "Resources" / "FrameworkInfo.plist").read_bytes())
        else:
            path.touch()


class MaterializingRunner:
    def __init__(self, fail_fragment=None):
        self.fail_fragment = fail_fragment
        self.calls = []

    def __call__(self, command, environment=None):
        self.calls.append(tuple(command))
        rendered = " ".join(str(argument) for argument in command)
        if self.fail_fragment and self.fail_fragment in rendered:
            return subprocess.CompletedProcess(command, 73, "", "injected failure")
        if "-o" in command:
            output = Path(command[command.index("-o") + 1])
            if "dsymutil" in command:
                executable = Path(command[command.index("-o") - 1]).name
                dwarf = output / "Contents" / "Resources" / "DWARF" / executable
                dwarf.parent.mkdir(parents=True, exist_ok=True)
                dwarf.touch()
            else:
                output.parent.mkdir(parents=True, exist_ok=True)
                output.touch()
        return subprocess.CompletedProcess(command, 0, "", "")


class DebuggerFixturePlanTests(unittest.TestCase):
    def test_selected_xcode27_toolchain_is_discovered_and_recorded(self):
        tool = load_fixture_tool()
        runner = ToolchainRunner()
        evidence = tool.discover_toolchain(
            Path("/Applications/Xcode-beta.app/Contents/Developer"), runner
        )

        self.assertEqual(evidence.xcode_major, 27)
        self.assertEqual(evidence.sdk_major, 27)
        self.assertEqual(evidence.tools["clang"], "/Selected/usr/bin/clang")
        self.assertEqual(evidence.tools["lldb-dap"], "/Selected/usr/bin/lldb-dap")
        self.assertTrue(
            all(
                environment.get("DEVELOPER_DIR")
                == "/Applications/Xcode-beta.app/Contents/Developer"
                for _, environment in runner.calls
            )
        )

    def test_toolchain_discovery_rejects_wrong_xcode_or_sdk_major(self):
        tool = load_fixture_tool()

        class WrongMajorRunner(ToolchainRunner):
            def __init__(self, wrong):
                super().__init__()
                self.wrong = wrong

            def __call__(self, command, environment=None):
                result = super().__call__(command, environment)
                if self.wrong == "xcode" and command[-1] == "-version":
                    return subprocess.CompletedProcess(command, 0, "Xcode 26.4\nBuild version X\n", "")
                if self.wrong == "sdk" and command[-1] == "--show-sdk-version":
                    return subprocess.CompletedProcess(command, 0, "28.0\n", "")
                return result

        for wrong in ("xcode", "sdk"):
            with self.subTest(wrong=wrong), self.assertRaises(tool.FixtureError):
                tool.discover_toolchain(
                    Path("/Applications/Xcode-beta.app/Contents/Developer"),
                    WrongMajorRunner(wrong),
                )

    def test_plan_has_stable_xcode27_commands_and_exact_topology(self):
        tool = load_fixture_tool()
        plan = tool.make_build_plan(
            source_root=Path("/source/debugger-fixture"),
            staging_root=Path("/temporary/stage"),
            output_root=Path("/products"),
            developer_directory=Path("/Applications/Xcode.app/Contents/Developer"),
            signing_fingerprint="A" * 40,
        )

        self.assertIsNotNone(plan, "deterministic build plan must be produced")
        self.assertEqual(plan.environment["DEVELOPER_DIR"], "/Applications/Xcode.app/Contents/Developer")
        self.assertEqual(
            [step.name for step in plan.steps],
            [
                "compile-runtime",
                "compile-main",
                "compile-helper",
                "compile-framework",
                "link-framework",
                "link-main",
                "link-helper",
                "dsym-framework",
                "dsym-main",
                "dsym-helper",
                "sign-framework",
                "sign-helper",
                "sign-app",
            ],
        )
        expected_identifiers = {
            "sign-framework": "org.macscope.app.debugger-fixture.runtime",
            "sign-helper": "org.macscope.app.debugger-fixture.helper",
            "sign-app": "org.macscope.app.debugger-fixture",
        }
        for step in plan.steps:
            if step.name in expected_identifiers:
                identifier_index = step.argv.index("--identifier")
                self.assertEqual(step.argv[identifier_index + 1], expected_identifiers[step.name])
        for step in plan.steps[:7]:
            self.assertIn("arm64-apple-macos27.0", step.argv)
            self.assertIn("-Wl,-no_adhoc_codesign", step.argv if step.name.startswith("link-") else ("-Wl,-no_adhoc_codesign",))
            if step.name.startswith("link-"):
                self.assertIn("-Wl,-oso_prefix,/temporary/stage/", step.argv)
        for step in plan.steps:
            if step.name.startswith("dsym-"):
                self.assertIn("--oso-prepend-path", step.argv)
                self.assertIn("/temporary/stage", step.argv)
        self.assertEqual(
            plan.required_relative_paths,
            (
                "MacScopeDebuggerFixture.app/Contents/Info.plist",
                "MacScopeDebuggerFixture.app/Contents/MacOS/MacScopeDebuggerFixture",
                "MacScopeDebuggerFixture.app/Contents/Frameworks/MacScopeDebuggerFixtureRuntime.framework/Info.plist",
                "MacScopeDebuggerFixture.app/Contents/Frameworks/MacScopeDebuggerFixtureRuntime.framework/MacScopeDebuggerFixtureRuntime",
                "MacScopeDebuggerFixture.app/Contents/Helpers/MacScopeDebuggerHelper",
                "MacScopeDebuggerFixture.app.dSYM/Contents/Resources/DWARF/MacScopeDebuggerFixture",
                "MacScopeDebuggerFixtureRuntime.framework.dSYM/Contents/Resources/DWARF/MacScopeDebuggerFixtureRuntime",
                "MacScopeDebuggerHelper.dSYM/Contents/Resources/DWARF/MacScopeDebuggerHelper",
            ),
        )

    def test_normalized_plan_is_independent_of_source_and_staging_roots(self):
        tool = load_fixture_tool()
        common = {
            "developer_directory": Path("/Applications/Xcode.app/Contents/Developer"),
            "signing_fingerprint": "B" * 40,
        }
        first = tool.make_build_plan(
            source_root=Path("/tmp/one/source"),
            staging_root=Path("/tmp/one/stage"),
            output_root=Path("/tmp/one/products"),
            **common,
        )
        second = tool.make_build_plan(
            source_root=Path("/private/tmp/two/source"),
            staging_root=Path("/private/tmp/two/stage"),
            output_root=Path("/private/tmp/two/products"),
            **common,
        )
        self.assertEqual(first.normalized_commands(), second.normalized_commands())


class DebuggerFixtureVerificationTests(unittest.TestCase):
    def test_explicit_approved_fingerprint_disambiguates_same_subject_certificates(self):
        tool = load_fixture_tool()
        runner = RecordingRunner()
        command_key = ("/usr/bin/security", "find-identity", "-v", "-p", "codesigning")
        runner.responses[command_key] = subprocess.CompletedProcess(
            command_key,
            0,
            '  1) %s "%s"\n  2) %s "%s"\n' % (
                "A" * 40,
                tool.APPROVED_SIGNER,
                "B" * 40,
                tool.APPROVED_SIGNER,
            ),
            "",
        )
        with self.assertRaises(tool.FixtureError):
            tool.resolve_signing_identity(runner)
        selected = tool.resolve_signing_identity(runner, approved_fingerprint="B" * 40)
        self.assertEqual(selected.fingerprint, "B" * 40)
        with self.assertRaises(tool.FixtureError):
            tool.resolve_signing_identity(runner, approved_fingerprint="C" * 40)

    def test_exact_signing_identity_and_artifacts_are_verified(self):
        tool = load_fixture_tool()
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            create_artifact_topology(root)
            runner = ArtifactRunner()
            identity = tool.resolve_signing_identity(runner)
            self.assertIsNotNone(identity, "approved signing identity must resolve")
            evidence = tool.verify_artifacts(root, runner)

        self.assertEqual(identity.fingerprint, "A" * 40)
        self.assertEqual(evidence["app"]["team"], ArtifactRunner.TEAM)
        self.assertTrue(evidence["app"]["entitlements"]["com.apple.security.get-task-allow"])
        self.assertEqual(evidence["framework"]["entitlements"], {})
        self.assertEqual(evidence["app"]["cdhash"], "0123456789abcdef0123456789abcdef01234567")
        self.assertNotEqual(evidence["app"]["uuid"], evidence["framework"]["uuid"])
        self.assertEqual(evidence["app"]["preferredAddress"], evidence["framework"]["preferredAddress"])

    def test_verification_rejects_wrong_team_uuid_and_preferred_address(self):
        tool = load_fixture_tool()
        variants = [
            ArtifactRunner(team="WRONGTEAM"),
            ArtifactRunner(uuid_mismatch=True),
            ArtifactRunner(preferred_mismatch=True),
        ]
        for runner in variants:
            with self.subTest(runner=runner.__dict__), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                create_artifact_topology(root)
                with self.assertRaises(tool.FixtureError):
                    tool.verify_artifacts(root, runner)

    def test_verification_rejects_symlink_and_unexpected_executable_payload(self):
        tool = load_fixture_tool()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            create_artifact_topology(root)
            helper = root / "MacScopeDebuggerFixture.app/Contents/Helpers/MacScopeDebuggerHelper"
            helper.unlink()
            helper.symlink_to("/bin/echo")
            with self.assertRaises(tool.FixtureError):
                tool.verify_artifacts(root, ArtifactRunner())

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            create_artifact_topology(root)
            unexpected = root / "MacScopeDebuggerFixture.app/Contents/Helpers/UnexpectedHelper"
            unexpected.write_text("payload", encoding="utf-8")
            unexpected.chmod(0o755)
            with self.assertRaises(tool.FixtureError):
                tool.verify_artifacts(root, ArtifactRunner())

    def test_verification_passes_selected_developer_environment_to_every_tool(self):
        tool = load_fixture_tool()

        class EnvironmentArtifactRunner(ArtifactRunner):
            def __init__(self):
                super().__init__()
                self.environments = []

            def __call__(self, command, environment=None):
                self.environments.append(dict(environment or {}))
                return super().__call__(command, environment)

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            create_artifact_topology(root)
            runner = EnvironmentArtifactRunner()
            tool.verify_artifacts(root, runner, {"DEVELOPER_DIR": "/Selected/Developer"})
        self.assertTrue(runner.environments)
        self.assertTrue(
            all(item.get("DEVELOPER_DIR") == "/Selected/Developer" for item in runner.environments)
        )

    def test_verification_uses_selected_xcode_macho_tools(self):
        tool = load_fixture_tool()
        tools = {
            name: "/Selected/usr/bin/%s" % name
            for name in (
                "clang", "ld", "dsymutil", "dwarfdump", "nm", "lipo", "vtool", "lldb", "lldb-dap"
            )
        }
        toolchain = tool.ToolchainEvidence(
            developer_directory="/Selected/Developer",
            xcode_version="Xcode 27.1",
            xcode_major=27,
            sdk_path="/Selected/SDKs/MacOSX27.1.sdk",
            sdk_version="27.1",
            sdk_major=27,
            tools=tools,
            tool_versions={name: "Xcode 27.1" for name in tools},
        )

        class SelectedToolRunner(ArtifactRunner):
            def __init__(self):
                super().__init__()
                self.original_calls = []

            def __call__(self, command, environment=None):
                self.original_calls.append(tuple(command))
                rewritten = list(command)
                selected_name = Path(rewritten[0]).name
                if rewritten[0].startswith("/Selected/usr/bin/"):
                    if selected_name == "lipo":
                        rewritten[0] = "/usr/bin/lipo"
                    else:
                        rewritten = ["/usr/bin/xcrun", selected_name, *rewritten[1:]]
                return super().__call__(rewritten, environment)

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            create_artifact_topology(root)
            runner = SelectedToolRunner()
            tool.verify_artifacts(
                root,
                runner,
                {"DEVELOPER_DIR": "/Selected/Developer"},
                toolchain=toolchain,
            )
        invoked = {Path(call[0]).name for call in runner.original_calls}
        self.assertTrue({"lipo", "vtool", "dwarfdump", "nm"}.issubset(invoked))

    def test_manifest_comparison_ignores_only_declared_signature_volatility(self):
        tool = load_fixture_tool()
        first = {
            "schema": 1,
            "buildRoot": "/tmp/one",
            "sourceHashes": {"main.c": "abc"},
            "artifacts": {"main": {"uuid": "U", "unsignedHash": "H", "cdhash": "one"}},
        }
        second = {
            "schema": 1,
            "buildRoot": "/tmp/two",
            "sourceHashes": {"main.c": "abc"},
            "artifacts": {"main": {"uuid": "U", "unsignedHash": "H", "cdhash": "two"}},
        }
        normalized = tool.normalize_manifest(first)
        self.assertIsNotNone(normalized, "normalized manifest must be produced")
        tool.compare_manifests(first, second)
        second["sourceHashes"]["main.c"] = "changed"
        with self.assertRaises(tool.FixtureError):
            tool.compare_manifests(first, second)

    def test_real_manifest_shape_excludes_volatile_signed_hashes_from_comparison(self):
        tool = load_fixture_tool()
        first = {
            "schema": 1,
            "sourceHashes": {"Sources/main.c": "same"},
            "unsignedHashes": {"app": "stable"},
            "signedHashes": {"app": "volatile-one"},
            "cdhashes": {"app": "volatile-cdhash-one"},
            "verification": {"app": {"uuid": "stable-uuid"}},
        }
        second = json.loads(json.dumps(first))
        second["signedHashes"]["app"] = "volatile-two"
        second["cdhashes"]["app"] = "volatile-cdhash-two"
        tool.compare_manifests(first, second)
        second["unsignedHashes"]["app"] = "changed"
        with self.assertRaises(tool.FixtureError):
            tool.compare_manifests(first, second)

    def test_designated_requirement_parser_rejects_extra_or_disjunctive_clauses(self):
        tool = load_fixture_tool()
        identifier = tool.APP_IDENTIFIER
        signer = tool.APPROVED_SIGNER
        exact = (
            'designated => identifier "%s" and anchor apple generic and '
            'certificate leaf[subject.CN] = "%s" and '
            'certificate 1[field.1.2.840.113635.100.6.2.1] exists\n'
        ) % (identifier, signer)
        self.assertEqual(tool.parse_exact_designated_requirement(exact, identifier), signer)
        commented = exact.replace("] exists", "] /* exists */")
        self.assertEqual(tool.parse_exact_designated_requirement(commented, identifier), signer)
        for invalid in (
            exact.rstrip() + " and true\n",
            exact.replace(" and anchor", " or anchor"),
            exact.replace('identifier "%s"' % identifier, 'identifier "wrong.%s"' % identifier),
        ):
            with self.assertRaises(tool.FixtureError):
                tool.parse_exact_designated_requirement(invalid, identifier)

    def test_entitlement_parser_treats_no_xml_as_empty_and_extracts_bounded_plist(self):
        tool = load_fixture_tool()
        self.assertEqual(tool.parse_codesign_entitlements("Executable=/tmp/framework\n"), {})
        payload = plistlib.dumps({"com.apple.security.get-task-allow": True}).decode()
        self.assertEqual(
            tool.parse_codesign_entitlements("diagnostic\n" + payload + "trailer\n"),
            {"com.apple.security.get-task-allow": True},
        )


class DebuggerFixtureCLITests(unittest.TestCase):
    def test_cli_exposes_build_verify_and_compare_commands(self):
        tool = load_fixture_tool()
        for command in ("build", "verify", "compare"):
            with self.subTest(command=command):
                output = StringIO()
                errors = StringIO()
                with redirect_stdout(output), redirect_stderr(errors):
                    status = tool.main([command, "--help"])
                self.assertEqual(status, 0)

    def test_compare_cli_reads_real_manifests_and_reports_stable_digest(self):
        tool = load_fixture_tool()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            first = root / "first.json"
            second = root / "second.json"
            payload = {
                "schema": 1,
                "unsignedHashes": {"app": "stable"},
                "signedHashes": {"app": "volatile-one"},
            }
            first.write_text(json.dumps(payload), encoding="utf-8")
            payload["signedHashes"]["app"] = "volatile-two"
            second.write_text(json.dumps(payload), encoding="utf-8")
            output = StringIO()
            with redirect_stdout(output):
                status = tool.main(
                    ["compare", "--first", str(first), "--second", str(second)]
                )
            self.assertEqual(status, 0)
            self.assertEqual(json.loads(output.getvalue())["status"], "equal")


class DebuggerFixtureTransactionTests(unittest.TestCase):
    def make_source_root(self, parent):
        source = parent / "fixture-source"
        resources = source / "Resources"
        resources.mkdir(parents=True)
        (resources / "AppInfo.plist").write_text("app", encoding="utf-8")
        (resources / "FrameworkInfo.plist").write_text("framework", encoding="utf-8")
        (resources / "DebuggableTarget.entitlements").write_text("entitlements", encoding="utf-8")
        sources = source / "Sources"
        sources.mkdir()
        for name in ("main.c", "helper.c", "framework.c", "fixture_runtime.c", "fixture_runtime.h"):
            (sources / name).write_text(name, encoding="utf-8")
        (source / "README.md").write_text("fixture", encoding="utf-8")
        (source / "fixture_tool.py").write_text("fixture tool", encoding="utf-8")
        return source

    def test_success_promotes_only_complete_verified_staging_tree(self):
        tool = load_fixture_tool()
        with tempfile.TemporaryDirectory() as directory:
            parent = Path(directory)
            source = self.make_source_root(parent)
            plan = tool.make_build_plan(
                source_root=source,
                staging_root=parent / "stage",
                output_root=parent / "accepted",
                developer_directory=Path("/Applications/Xcode.app/Contents/Developer"),
                signing_fingerprint="A" * 40,
            )
            accepted = tool.execute_build(plan, MaterializingRunner(), lambda root: {"verified": True})
            self.assertEqual(accepted, parent / "accepted")
            self.assertFalse((parent / "stage").exists())
            self.assertTrue((accepted / "MacScopeDebuggerFixture.app").is_dir())

    def test_compile_link_sign_and_verify_failures_never_promote(self):
        tool = load_fixture_tool()
        cases = ["fixture_runtime.c", "-dynamiclib", "--sign", "verify"]
        for index, failure in enumerate(cases):
            with self.subTest(failure=failure), tempfile.TemporaryDirectory() as directory:
                parent = Path(directory)
                source = self.make_source_root(parent)
                plan = tool.make_build_plan(
                    source_root=source,
                    staging_root=parent / "stage",
                    output_root=parent / "accepted",
                    developer_directory=Path("/Applications/Xcode.app/Contents/Developer"),
                    signing_fingerprint="A" * 40,
                )
                runner = MaterializingRunner(None if failure == "verify" else failure)

                def verifier(root):
                    if failure == "verify":
                        raise tool.FixtureError("injected verify failure")
                    return {"verified": True}

                with self.assertRaises(tool.FixtureError):
                    tool.execute_build(plan, runner, verifier)
                self.assertFalse(plan.staging_root.exists())
                self.assertFalse(plan.output_root.exists())

    def test_manifest_hashes_only_frozen_fixture_inputs(self):
        tool = load_fixture_tool()
        with tempfile.TemporaryDirectory() as directory:
            parent = Path(directory)
            source = self.make_source_root(parent)
            generated = source / "__pycache__" / "fixture_tool.pyc"
            generated.parent.mkdir()
            generated.write_bytes(b"volatile")
            plan = tool.make_build_plan(
                source_root=source,
                staging_root=parent / "stage",
                output_root=parent / "accepted",
                developer_directory=Path("/Applications/Xcode.app/Contents/Developer"),
                signing_fingerprint="A" * 40,
            )
            accepted = tool.execute_build(plan, MaterializingRunner(), lambda root: {"verified": True})
            manifest = json.loads((accepted / "manifest.json").read_text(encoding="utf-8"))
            self.assertNotIn("__pycache__/fixture_tool.pyc", manifest["sourceHashes"])
            self.assertEqual(set(manifest["sourceHashes"]), set(tool.FIXTURE_SOURCE_INPUTS))


class DebuggerFixtureSourceContractTests(unittest.TestCase):
    def test_source_resource_and_documentation_inventory_is_complete(self):
        expected = {
            "README.md",
            "Sources/main.c",
            "Sources/helper.c",
            "Sources/framework.c",
            "Sources/fixture_runtime.c",
            "Sources/fixture_runtime.h",
            "Resources/AppInfo.plist",
            "Resources/FrameworkInfo.plist",
            "Resources/DebuggableTarget.entitlements",
        }
        actual = {
            str(path.relative_to(FIXTURE_ROOT))
            for path in FIXTURE_ROOT.rglob("*")
            if path.is_file() and path.name != "fixture_tool.py"
        }
        self.assertTrue(expected.issubset(actual), "fixture source inventory is incomplete")

        main_source = (FIXTURE_ROOT / "Sources" / "main.c").read_text(encoding="utf-8")
        helper_source = (FIXTURE_ROOT / "Sources" / "helper.c").read_text(encoding="utf-8")
        framework_source = (FIXTURE_ROOT / "Sources" / "framework.c").read_text(encoding="utf-8")
        runtime_source = (FIXTURE_ROOT / "Sources" / "fixture_runtime.c").read_text(encoding="utf-8")
        self.assertIn("macscope_fixture_main_checkpoint", main_source)
        self.assertIn("macscope_fixture_helper_checkpoint", helper_source)
        self.assertIn("macscope_fixture_framework_checkpoint", framework_source)
        self.assertIn("__MACSCOPE,__probe", main_source)
        self.assertIn("__MACSCOPE,__probe", framework_source)
        for operation in ["load", "checkpoint", "unload", "exit"]:
            self.assertIn('"%s"' % operation, runtime_source)
        self.assertIn("if (errno == EINTR)", runtime_source)
        self.assertIn("clearerr(commands);", runtime_source)

        with (FIXTURE_ROOT / "Resources" / "AppInfo.plist").open("rb") as stream:
            app_info = plistlib.load(stream)
        with (FIXTURE_ROOT / "Resources" / "FrameworkInfo.plist").open("rb") as stream:
            framework_info = plistlib.load(stream)
        with (FIXTURE_ROOT / "Resources" / "DebuggableTarget.entitlements").open("rb") as stream:
            entitlements = plistlib.load(stream)
        self.assertEqual(app_info["LSMinimumSystemVersion"], "27.0")
        self.assertEqual(framework_info["CFBundleExecutable"], "MacScopeDebuggerFixtureRuntime")
        self.assertEqual(entitlements, {"com.apple.security.get-task-allow": True})


if __name__ == "__main__":
    unittest.main()
