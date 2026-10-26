#!/usr/bin/env python3

from __future__ import annotations

import hashlib
import json
import plistlib
import subprocess
import tempfile
import unittest
import importlib.util
import inspect
import os
import shlex
import shutil
import stat
import sys
from pathlib import Path
from unittest.mock import patch


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
GUARD = REPOSITORY_ROOT / "Scripts" / "check_local_signing_policy.py"

XCODE_TEST_HOST_ENTITLEMENTS_FIXTURE = {
    "com.apple.security.get-task-allow": True,
    "com.apple.security.temporary-exception.files.absolute-path.read-only": ["/"],
    "com.apple.security.temporary-exception.mach-lookup.global-name": [
        "com.apple.testmanagerd",
        "com.apple.dt.testmanagerd.runner",
        "com.apple.coresymbolicationd",
    ],
}
SHELL_BROKER_LAUNCH_AGENT_ENTITLEMENTS_FIXTURE = {
    "com.apple.application-identifier": (
        "TEAM000000.org.macscope.app.ShellBrokerLaunchAgent"
    ),
    **XCODE_TEST_HOST_ENTITLEMENTS_FIXTURE,
}
RELEASE_SHELL_BROKER_LAUNCH_AGENT_ENTITLEMENTS_FIXTURE = {
    "com.apple.application-identifier": (
        "TEAM000000.org.macscope.app.ShellBrokerLaunchAgent"
    ),
    "com.apple.security.get-task-allow": True,
}
SIGNER_SUBJECT_FIXTURE = (
    "Apple Development:"
    " MacScope Developer (CERT000000)"
)


def load_guard_module():
    specification = importlib.util.spec_from_file_location("check_local_signing_policy", GUARD)
    assert specification is not None and specification.loader is not None
    module = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(module)
    return module


def set_fixture_xattr(path: Path, value: bytes) -> None:
    name = "user.macscope.equality-test"
    if hasattr(os, "setxattr"):
        os.setxattr(path, name, value)
    elif sys.platform == "darwin":
        subprocess.run(["/usr/bin/xattr", "-w", name, value.decode("ascii"), str(path)],
                       check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    else:
        raise RuntimeError("test host has no extended-attribute mutation API")


def make_generated_project_freshness_fixture(root: Path) -> Path:
    macscope = root / "MacScope"
    xcodeproj = macscope / "MacScope.xcodeproj"
    xcodeproj.mkdir(parents=True)
    project = macscope / "project.yml"
    project.write_text("name: MacScope\n", encoding="utf-8")
    (macscope / "SigningIdentity.xcconfig").write_text(
        "MACSCOPE_SIGNING_IDENTITY = Apple Development: MacScope Developer (CERT000000)\n"
        "MACSCOPE_SIGNING_TEAM = TEAM000000\n",
        encoding="utf-8",
    )
    (macscope / "DependencyRoots.xcconfig").write_text(
        '#include "SigningIdentity.xcconfig"\n'
        "MACSCOPE_GHOSTTY_SOURCE_DIR =\n"
        "MACSCOPE_SLEIGH_MATERIALIZATION_ROOT =\n"
        "MACSCOPE_MACHOKIT_MATERIALIZATION_ROOT =\n"
        "MACSCOPE_GHOSTTY_SURFACE_SOURCE_DIR =\n"
        "MACSCOPE_GHOSTTY_SURFACE_ARTIFACT_ROOT =\n"
        "MACSCOPE_GHOSTTY_SURFACE_FRAMEWORK =\n"
        "MACSCOPE_GHOSTTY_SURFACE_ENABLED =\n"
        '#include? "DependencyRoots.local.xcconfig"\n',
        encoding="utf-8",
    )
    (xcodeproj / "project.xcproj").write_text(
        "// generated project\n", encoding="utf-8"
    )
    overlay = root / "ThirdParty" / "SleighNative"
    overlay.mkdir(parents=True)
    (overlay / "PATCHED_RESOURCES.json").write_text('{"fixture": "sleigh overlay"}\n', encoding="utf-8")
    return project


class ArtifactFixtureRunner:
    """Return realistic command results without reading the host keychain."""

    def __init__(self, configuration: str = "Release") -> None:
        self.configuration = configuration
        self.calls: list[tuple[str, ...]] = []
        self.results: dict[tuple[str, str], subprocess.CompletedProcess[str]] = {}

    @staticmethod
    def target_for(command: list[str]) -> str:
        if "CoreTests.xctest" in command[-1]:
            return "core_tests"
        if command[-1].endswith("/libghostty-vt.dylib"):
            return "ghostty_vt"
        if command[-1].endswith("/SourceExecutionRunner"):
            return "source_runner"
        if command[-1].endswith("/ShellBrokerLaunchAgent"):
            return "shell_launch_agent"
        if "NativeDecompilerXPCService" in command[-1]:
            return "native_decompiler"
        if "AIAgentWorkerXPCService" in command[-1]:
            return "ai_worker"
        if "AnalysisWorkerXPCService" in command[-1]:
            return "worker"
        if "ShellBrokerXPCService" in command[-1]:
            return "shell_broker"
        if "PluginXPCService" in command[-1]:
            return "plugin"
        return "app"

    @staticmethod
    def action_for(command: list[str]) -> str:
        if command[0] == "/usr/bin/lipo":
            return "architecture"
        if command[:3] == ["/usr/bin/xcrun", "vtool", "-show-build"]:
            return "deployment"
        if "--verify" in command:
            return "verify"
        if "-r-" in command:
            return "requirements"
        if "--entitlements" in command:
            return "entitlements"
        if "-dvvv" in command:
            return "details"
        raise AssertionError(f"unexpected artifact validation command: {command!r}")

    def __call__(self, command: list[str]) -> subprocess.CompletedProcess[str]:
        self.calls.append(tuple(command))
        action = self.action_for(command)
        target = self.target_for(command)
        overridden = self.results.get((action, target))
        if overridden is not None:
            return overridden

        identifier = {
            "app": "org.macscope.app",
            "native_decompiler": "org.macscope.app.NativeDecompiler",
            "ai_worker": "org.macscope.app.AIAgentWorker",
            "worker": "org.macscope.app.AnalysisWorker",
            "plugin": "org.macscope.app.PluginXPCService",
            "shell_broker": "org.macscope.app.ShellBroker",
            "core_tests": "org.macscope.app.CoreTests",
            "shell_launch_agent": "org.macscope.app.ShellBrokerLaunchAgent",
            "source_runner": "org.macscope.app.SourceExecutionRunner",
            "ghostty_vt": "org.macscope.app.GhosttyVT",
        }[target]
        if action == "verify":
            return subprocess.CompletedProcess(command, 0, "", "")
        if action == "details":
            details = f"""\
Executable={command[-1]}/Contents/MacOS/Product
Identifier={identifier}
Format=bundle with Mach-O thin (arm64)
CodeDirectory v=20500 size=842 flags=0x10000(runtime) hashes=16+7 location=embedded
Authority=Apple Development: MacScope Developer (CERT000000)
Authority=Apple Worldwide Developer Relations Certification Authority
Authority=Apple Root CA
TeamIdentifier=TEAM000000
"""
            return subprocess.CompletedProcess(command, 0, "", details)
        if action == "requirements":
            requirements = (
                f'designated => anchor apple generic and identifier "{identifier}" '
                'and certificate leaf[subject.CN] = '
                '"Apple Development: MacScope Developer (CERT000000)" '
                'and certificate 1[field.1.2.840.113635.100.6.2.1] exists\n'
            )
            return subprocess.CompletedProcess(command, 0, "", requirements)
        if action == "entitlements":
            profile = (
                RELEASE_SHELL_BROKER_LAUNCH_AGENT_ENTITLEMENTS_FIXTURE
                if target == "shell_launch_agent" and self.configuration == "Release"
                else {}
            )
            if target == "source_runner" and self.configuration == "Release":
                profile = {"com.apple.application-identifier": "TEAM000000.org.macscope.app.SourceExecutionRunner", "com.apple.security.get-task-allow": True}
            entitlements = plistlib.dumps(profile).decode("utf-8")
            return subprocess.CompletedProcess(command, 0, entitlements, "")
        if action == "architecture":
            return subprocess.CompletedProcess(command, 0, "arm64\n", "")
        if action == "deployment":
            build_version = f"""\
{command[-1]}:
Load command 11
      cmd LC_BUILD_VERSION
  cmdsize 32
 platform MACOS
    minos 27.0
      sdk 27.0
   ntools 1
"""
            return subprocess.CompletedProcess(command, 0, build_version, "")
        raise AssertionError(f"unhandled action: {action}")

    def override(
        self,
        action: str,
        target: str,
        *,
        returncode: int = 0,
        stdout: str = "",
        stderr: str = "",
    ) -> None:
        self.results[(action, target)] = subprocess.CompletedProcess(
            [action, target], returncode, stdout, stderr
        )


class ToolchainFixtureRunner:
    """Return Xcode 27 and its bundled Swift evidence without invoking host tools."""

    def __init__(self) -> None:
        self.calls: list[tuple[str, ...]] = []
        self.overrides: dict[tuple[str, ...], subprocess.CompletedProcess[str]] = {}

    def __call__(
        self,
        command: list[str],
        environment: dict[str, str],
    ) -> subprocess.CompletedProcess[str]:
        self.calls.append(tuple(command))
        override = self.overrides.get(tuple(command))
        if override is not None:
            return override
        developer_directory = environment["DEVELOPER_DIR"]
        outputs = {
            ("/usr/bin/uname", "-m"): "arm64\n",
            ("/usr/bin/sw_vers", "-productVersion"): "28.0\n",
            ("/usr/bin/xcrun", "xcodebuild", "-version"): (
                "Xcode 27.0\nBuild version 27A5218g\n"
            ),
            ("/usr/bin/xcrun", "--sdk", "macosx", "--show-sdk-version"): "27.0\n",
            ("/usr/bin/xcrun", "--find", "swift"): (
                f"{developer_directory}/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift\n"
            ),
            ("/usr/bin/xcrun", "swift", "--version"): (
                "Apple Swift version 6.4 (swiftlang-test clang-test)\n"
            ),
        }
        output = outputs.get(tuple(command))
        if output is None:
            raise AssertionError(f"unexpected toolchain command: {command!r}")
        return subprocess.CompletedProcess(command, 0, output, "")

    def override(
        self,
        command: tuple[str, ...],
        *,
        returncode: int = 0,
        stdout: str = "",
        stderr: str = "",
    ) -> None:
        self.overrides[command] = subprocess.CompletedProcess(
            list(command), returncode, stdout, stderr
        )


def make_artifact_bundle(root: Path) -> Path:
    app = root / "MacScope.app"
    app_contents = app / "Contents"
    app_macos = app_contents / "MacOS"
    worker = app_contents / "XPCServices" / "AnalysisWorkerXPCService.xpc"
    worker_contents = worker / "Contents"
    worker_macos = worker_contents / "MacOS"
    ai_worker = app_contents / "XPCServices" / "AIAgentWorkerXPCService.xpc"
    ai_worker_contents = ai_worker / "Contents"
    ai_worker_macos = ai_worker_contents / "MacOS"
    shell_broker = app_contents / "XPCServices" / "ShellBrokerXPCService.xpc"
    shell_broker_contents = shell_broker / "Contents"
    shell_broker_macos = shell_broker_contents / "MacOS"
    native_decompiler = (
        app_contents / "XPCServices" / "NativeDecompilerXPCService.xpc"
    )
    native_decompiler_contents = native_decompiler / "Contents"
    native_decompiler_macos = native_decompiler_contents / "MacOS"
    app_macos.mkdir(parents=True)
    worker_macos.mkdir(parents=True)
    ai_worker_macos.mkdir(parents=True)
    shell_broker_macos.mkdir(parents=True)
    native_decompiler_macos.mkdir(parents=True)
    frameworks = app_contents / "Frameworks"
    frameworks.mkdir()

    with (app_contents / "Info.plist").open("wb") as stream:
        plistlib.dump(
            {
                "CFBundleIdentifier": "org.macscope.app",
                "CFBundleExecutable": "MacScope",
            },
            stream,
        )
    with (worker_contents / "Info.plist").open("wb") as stream:
        plistlib.dump(
            {
                "CFBundleIdentifier": "org.macscope.app.AnalysisWorker",
                "CFBundleExecutable": "AnalysisWorkerXPCService",
            },
            stream,
        )
    with (ai_worker_contents / "Info.plist").open("wb") as stream:
        plistlib.dump(
            {
                "CFBundleIdentifier": "org.macscope.app.AIAgentWorker",
                "CFBundleExecutable": "AIAgentWorkerXPCService",
            },
            stream,
        )
    with (shell_broker_contents / "Info.plist").open("wb") as stream:
        plistlib.dump(
            {
                "CFBundleIdentifier": "org.macscope.app.ShellBroker",
                "CFBundleExecutable": "ShellBrokerXPCService",
            },
            stream,
        )
    with (native_decompiler_contents / "Info.plist").open("wb") as stream:
        plistlib.dump(
            {
                "CFBundleIdentifier": "org.macscope.app.NativeDecompiler",
                "CFBundleExecutable": "NativeDecompilerXPCService",
            },
            stream,
        )
    (app_macos / "MacScope").touch()
    (app_macos / "ShellBrokerLaunchAgent").touch()
    (app_macos / "SourceExecutionRunner").touch()
    (worker_macos / "AnalysisWorkerXPCService").touch()
    (ai_worker_macos / "AIAgentWorkerXPCService").touch()
    (shell_broker_macos / "ShellBrokerXPCService").touch()
    (native_decompiler_macos / "NativeDecompilerXPCService").touch()
    (frameworks / "libghostty-vt.dylib").touch()
    signed_bundles = (
        app,
        worker,
        ai_worker,
        native_decompiler,
        shell_broker,
    )
    for signed_bundle in signed_bundles:
        code_resources = signed_bundle / "Contents/_CodeSignature/CodeResources"
        code_resources.parent.mkdir(parents=True)
        code_resources.write_bytes(
            f"sealed:{signed_bundle.name}\n".encode("utf-8")
        )

    resources = app_contents / "Resources"
    resources.mkdir()
    analysis_executable = worker_macos / "AnalysisWorkerXPCService"
    native_executable = native_decompiler_macos / "NativeDecompilerXPCService"
    native_code_resources = (
        native_decompiler_contents / "_CodeSignature/CodeResources"
    )
    digest = lambda path: hashlib.sha256(path.read_bytes()).hexdigest()
    provenance = {
        "schema_version": 1,
        "qualification_eligible": True,
        "configuration": "Release",
        "git_head_commit": "1" * 40,
        "git_head_tree": "2" * 40,
        "repository_clean": True,
        "selected_build_inputs_sha256": "3" * 64,
        "project_yml_sha256": "4" * 64,
        "architecture": "arm64",
        "deployment_target": "27.0",
        "app_bundle_identifier": "org.macscope.app",
        "ghostty_surface_compilation_condition": "MACSCOPE_FULL_GHOSTTY_SURFACE",
        "ghostty_surface_source_manifest_sha256": "5" * 64,
        "ghostty_surface_source_revision": (
            "f64f4aca2c29b554d111b36c3d946a9bddd159ff"
        ),
        "ghostty_surface_source_tree": (
            "de6cd65b35a423d5d6854c6af3a90be20a52d7eb"
        ),
        "ghostty_surface_source_sha256": (
            "ead5d48a8cda07addb59af1f35c6c9f7226bbdbd977b7330afd9714ecec6d8ab"
        ),
        "ghostty_surface_external_io_abi_version": 1,
        "ghostty_surface_build_profile_sha256": (
            "3679b0b75fc54d4698da134c9edd1055290b15d55b5fd6179e0bf0bc9ad1e502"
        ),
        "ghostty_surface_staged_tree_sha256": "6" * 64,
        "ghostty_surface_staged_descriptor_relative_path": (
            "STAGED_GHOSTTY_SURFACE.json"
        ),
        "ghostty_surface_staged_descriptor_sha256": "7" * 64,
        "ghostty_surface_archive_relative_path": "libghostty-internal.a",
        "ghostty_surface_archive_sha256": "8" * 64,
        "ghostty_surface_header_relative_path": "Headers/ghostty.h",
        "ghostty_surface_header_sha256": "9" * 64,
        "ghostty_surface_module_map_relative_path": "Headers/module.modulemap",
        "ghostty_surface_module_map_sha256": "a" * 64,
        "machokit_analysis_worker_executable_sha256": digest(analysis_executable),
        "native_decompiler_embedded_service_executable_sha256": digest(
            native_executable
        ),
        "native_decompiler_embedded_service_code_resources_sha256": digest(
            native_code_resources
        ),
    }
    provenance_path = resources / "MacScopeBuildProvenance.json"
    provenance_path.write_bytes(
        (json.dumps(provenance, sort_keys=True, separators=(",", ":")) + "\n").encode(
            "utf-8"
        )
    )
    provenance_path.chmod(0o644)
    return app


def update_release_provenance(app: Path, **changes: object) -> Path:
    path = app / "Contents/Resources/MacScopeBuildProvenance.json"
    payload = json.loads(path.read_bytes())
    payload.update(changes)
    path.write_bytes(
        (json.dumps(payload, sort_keys=True, separators=(",", ":")) + "\n").encode(
            "utf-8"
        )
    )
    path.chmod(0o644)
    return path


def add_plugin_artifact(app: Path) -> Path:
    plugin = app / "Contents" / "XPCServices" / "PluginXPCService.xpc"
    plugin_contents = plugin / "Contents"
    plugin_macos = plugin_contents / "MacOS"
    plugin_macos.mkdir(parents=True)
    with (plugin_contents / "Info.plist").open("wb") as stream:
        plistlib.dump(
            {
                "CFBundleIdentifier": "org.macscope.app.PluginXPCService",
                "CFBundleExecutable": "PluginXPCService",
            },
            stream,
        )
    (plugin_macos / "PluginXPCService").touch()
    code_resources = plugin_contents / "_CodeSignature/CodeResources"
    code_resources.parent.mkdir()
    code_resources.write_bytes(b"sealed:PluginXPCService.xpc\n")
    return plugin


def add_xcode_test_host_artifacts(app: Path) -> tuple[Path, Path]:
    core_tests = app / "Contents" / "PlugIns" / "CoreTests.xctest"
    core_tests_contents = core_tests / "Contents"
    core_tests_macos = core_tests_contents / "MacOS"
    core_tests_macos.mkdir(parents=True)
    with (core_tests_contents / "Info.plist").open("wb") as stream:
        plistlib.dump(
            {
                "CFBundleIdentifier": "org.macscope.app.CoreTests",
                "CFBundleExecutable": "CoreTests",
            },
            stream,
        )
    (core_tests_macos / "CoreTests").touch()
    code_resources = core_tests_contents / "_CodeSignature/CodeResources"
    code_resources.parent.mkdir()
    code_resources.write_bytes(b"sealed:CoreTests.xctest\n")

    launch_agent = app / "Contents" / "MacOS" / "ShellBrokerLaunchAgent"
    launch_agent.touch()
    return core_tests, launch_agent


def xcode_test_host_fixture_runner() -> ArtifactFixtureRunner:
    runner = ArtifactFixtureRunner(configuration="Debug")
    xcode_profile = plistlib.dumps(XCODE_TEST_HOST_ENTITLEMENTS_FIXTURE).decode(
        "utf-8"
    )
    for target in ("app", "worker", "ai_worker", "native_decompiler", "shell_broker"):
        runner.override("entitlements", target, stdout=xcode_profile)
    runner.override(
        "entitlements",
        "shell_launch_agent",
        stdout=plistlib.dumps(
            SHELL_BROKER_LAUNCH_AGENT_ENTITLEMENTS_FIXTURE
        ).decode("utf-8"),
    )
    runner.override("entitlements", "source_runner", stdout=plistlib.dumps({
        "com.apple.application-identifier": "TEAM000000.org.macscope.app.SourceExecutionRunner",
        **XCODE_TEST_HOST_ENTITLEMENTS_FIXTURE,
    }).decode("utf-8"))
    return runner


def signed_details_fixture(
    identifier: str,
    *,
    runtime: bool = True,
    signer: str = SIGNER_SUBJECT_FIXTURE,
    team: str = "TEAM000000",
) -> str:
    flags = "flags=0x10000(runtime)" if runtime else "flags=0x0(none)"
    return (
        f"Identifier={identifier}\n"
        f"CodeDirectory v=20500 {flags}\n"
        f"Authority={signer}\n"
        "Authority=Apple Worldwide Developer Relations Certification Authority\n"
        "Authority=Apple Root CA\n"
        f"TeamIdentifier={team}\n"
    )


def designated_requirement_fixture(
    identifier: str,
    *,
    signer: str = SIGNER_SUBJECT_FIXTURE,
) -> str:
    return (
        f'designated => anchor apple generic and identifier "{identifier}" '
        f'and certificate leaf[subject.CN] = "{signer}" '
        "and certificate 1[field.1.2.840.113635.100.6.2.1] exists\n"
    )


class LocalSigningPolicyTests(unittest.TestCase):
    def test_installed_ui_entitlement_exception_is_exact_and_physically_bound(self) -> None:
        module = load_guard_module()
        relative = "Tests/MacScopeInstalledAppUITests/InstalledAppUITests.entitlements"
        expected = {"com.apple.security.temporary-exception.shared-preference.read-write": ["org.macscope.app"]}
        text = (REPOSITORY_ROOT / "MacScope/project.yml").read_text()
        text = text.replace("        PRODUCT_NAME: MacScopeInstalledAppUITests\n",
                            f"        PRODUCT_NAME: MacScopeInstalledAppUITests\n        CODE_SIGN_ENTITLEMENTS: {relative}\n")
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            entitlement = root / relative
            entitlement.parent.mkdir(parents=True)
            entitlement.write_bytes(plistlib.dumps(expected))
            self.assertEqual(module.validate_project_settings(text, project_directory=root), [])
            mutations = (
                text.replace(relative, "../" + relative),
                text.replace("  MacScopeInstalledAppUITests:\n", "  UnauthorizedUITests:\n", 1),
                text.replace(f"CODE_SIGN_ENTITLEMENTS: {relative}", f"CODE_SIGN_ENTITLEMENTS: {relative}\n        ENABLE_APP_SANDBOX: NO"),
                text.replace(f"CODE_SIGN_ENTITLEMENTS: {relative}", f"CODE_SIGN_ENTITLEMENTS: {relative}\n        ENABLE_HARDENED_RUNTIME: NO"),
                text.replace(f"CODE_SIGN_ENTITLEMENTS: {relative}", f"CODE_SIGN_ENTITLEMENTS: {relative}\n        CODE_SIGN_IDENTITY: -"),
            )
            for mutation in mutations:
                with self.subTest(project=mutation[-150:]):
                    self.assertTrue(module.validate_project_settings(mutation, project_directory=root))
            for value in (
                {**expected, "com.apple.security.app-sandbox": False},
                {**expected, "com.apple.security.files.user-selected.read-write": True},
                {next(iter(expected)): ["com.other.app"]},
                {next(iter(expected)): ["org.macscope.app", "com.other.app"]},
                {},
            ):
                entitlement.write_bytes(plistlib.dumps(value))
                with self.subTest(entitlements=value):
                    self.assertTrue(module.validate_project_settings(text, project_directory=root))
            entitlement.write_bytes(plistlib.dumps(expected))
            preserved = root / "preserved.plist"
            entitlement.rename(preserved)
            entitlement.symlink_to(preserved)
            self.assertTrue(module.validate_project_settings(text, project_directory=root))
            entitlement.unlink()
            entitlement.parent.rename(root / "relocated")
            entitlement.parent.symlink_to(root / "relocated", target_is_directory=True)
            (root / "relocated" / entitlement.name).write_bytes(plistlib.dumps(expected))
            self.assertTrue(module.validate_project_settings(text, project_directory=root))

    def test_native_json_project_file_preserves_provenance_authority(self) -> None:
        from Scripts.tests.test_xcode_project_json import project_fixture

        module = load_guard_module()
        with tempfile.TemporaryDirectory() as temporary:
            project = Path(temporary) / "MacScope.xcodeproj"
            project.mkdir()
            project_file = project / "project.xcproj"
            value = project_fixture()
            project_file.write_text(json.dumps(value), encoding="utf-8")
            self.assertEqual(module.validate_generated_project_provenance_phase(project), [])
            for target in value["targets"]:
                phase = target["build-phases"][-1]
                original = phase["script"][:]
                for replacement in (
                    ['if [ "$CONFIGURATION" != "Release" ]; then', "exit 0", "fi"],
                    ['if [ "$CONFIGURATION" != "Release" ]; then', "exit 1", "fi"],
                    ['if [ "$CONFIGURATION" != "Release" ] && [ "$CONFIGURATION" != "Debug" ]; then', "exit 0", "fi"],
                    ['if [ "$CONFIGURATION" = "Debug" ]; then', "exit 0", "fi"],
                    [],
                ):
                    offset = 0 if target["name"] == "MacScopeApp" else 1
                    phase["script"] = original[:offset] + replacement + original[offset + 3:]
                    project_file.write_text(json.dumps(value), encoding="utf-8")
                    with self.subTest(target=target["name"], guard=replacement):
                        errors = module.validate_generated_project_provenance_phase(project)
                        self.assertTrue(any("never bypass Debug" in error for error in errors), errors)
                phase["script"] = original
            # The native JSON entrypoint must enforce the full Ghostty closure,
            # not merely rely on project.yml or an earlier PBX-format check.
            value["targets"][0]["build-phases"][-1]["input-paths"].remove(
                module.RELEASE_PROVENANCE_GHOSTTY_SURFACE_INPUTS[0]
            )
            project_file.write_text(json.dumps(value), encoding="utf-8")
            errors = module.validate_generated_project_provenance_phase(project)
            self.assertTrue(any("exact ordered input" in error for error in errors), errors)

    def run_guard(
        self,
        project_text: str,
        workflow_text: str,
        *,
        signing_text: str | None = None,
        dependency_text: str | None = None,
    ) -> subprocess.CompletedProcess[str]:
        with tempfile.TemporaryDirectory() as temporary_directory:
            # macOS TemporaryDirectory can use /var, an alias of /private/var.
            # The guard deliberately requires the physical project directory.
            root = Path(temporary_directory).resolve(strict=True)
            entitlement_relative = Path(
                "Tests/MacScopeInstalledAppUITests/InstalledAppUITests.entitlements"
            )
            entitlement = root / entitlement_relative
            entitlement.parent.mkdir(parents=True)
            entitlement.write_bytes(
                (REPOSITORY_ROOT / "MacScope" / entitlement_relative).read_bytes()
            )
            project = root / "project.yml"
            workflow = root / "ci.yml"
            signing = root / "SigningIdentity.xcconfig"
            dependency = root / "DependencyRoots.xcconfig"
            project.write_text(project_text, encoding="utf-8")
            workflow.write_text(workflow_text, encoding="utf-8")
            signing.write_text(
                signing_text
                if signing_text is not None
                else (REPOSITORY_ROOT / "MacScope/SigningIdentity.xcconfig").read_text(
                    encoding="utf-8"
                ),
                encoding="utf-8",
            )
            dependency.write_text(
                dependency_text
                if dependency_text is not None
                else (REPOSITORY_ROOT / "MacScope/DependencyRoots.xcconfig").read_text(
                    encoding="utf-8"
                ),
                encoding="utf-8",
            )
            return subprocess.run(
                [
                    "/usr/bin/python3",
                    str(GUARD),
                    "--project-yml",
                    str(project),
                    "--ci-yml",
                    str(workflow),
                    "--signing-identity-xcconfig",
                    str(signing),
                    "--dependency-roots-xcconfig",
                    str(dependency),
                ],
                check=False,
                capture_output=True,
                text=True,
            )

    def test_accepts_checked_in_local_and_ci_signing_policies(self) -> None:
        result = self.run_guard(
            (REPOSITORY_ROOT / "MacScope" / "project.yml").read_text(encoding="utf-8"),
            (REPOSITORY_ROOT / ".github" / "workflows" / "ci.yml").read_text(encoding="utf-8"),
        )

        self.assertEqual(result.returncode, 0, result.stderr)

    def test_exact_local_signer_uses_manual_profileless_signing(self) -> None:
        module = load_guard_module()
        project_text = (REPOSITORY_ROOT / "MacScope" / "project.yml").read_text(
            encoding="utf-8"
        )
        settings = module.parse_scalar_mapping(project_text)

        self.assertEqual(
            settings[("settings", "base", "CODE_SIGN_STYLE")],
            "Manual",
        )
        self.assertEqual(
            settings[("settings", "base", "PROVISIONING_PROFILE")],
            "",
        )
        self.assertEqual(
            settings[("settings", "base", "PROVISIONING_PROFILE_SPECIFIER")],
            "",
        )

    def test_signing_identity_declaration_matches_independent_guard_constants(self) -> None:
        module = load_guard_module()
        declaration = (REPOSITORY_ROOT / "MacScope/SigningIdentity.xcconfig").read_text(
            encoding="utf-8"
        )
        self.assertEqual(module.validate_signing_identity_declaration(declaration), [])
        mutations = {
            "alternate identity": declaration.replace(
                module.EXPECTED_SIGNER_SUBJECT,
                "Apple " + "Development: Different Developer (OTHERID123)",
            ),
            "alternate team": declaration.replace("TEAM000000", "OTHERTEAM1"),
            "missing identity": "\n".join(
                line
                for line in declaration.splitlines()
                if not line.startswith("MACSCOPE_SIGNING_IDENTITY =")
            ),
            "duplicate identity": declaration
            + f"MACSCOPE_SIGNING_IDENTITY = {module.EXPECTED_SIGNER_SUBJECT}\n",
            "conditional identity": declaration.replace(
                "MACSCOPE_SIGNING_IDENTITY =",
                "MACSCOPE_SIGNING_IDENTITY[sdk=macosx*] =",
            ),
            "direct signing setting": declaration + "CODE_SIGN_IDENTITY = -\n",
            "included authority": declaration + '#include "Other.xcconfig"\n',
        }
        for name, mutated in mutations.items():
            with self.subTest(name=name):
                errors = module.validate_signing_identity_declaration(mutated)
                self.assertNotEqual(errors, [])

        project = (REPOSITORY_ROOT / "MacScope/project.yml").read_text(encoding="utf-8")
        workflow = (REPOSITORY_ROOT / ".github/workflows/ci.yml").read_text(
            encoding="utf-8"
        )
        result = self.run_guard(
            project,
            workflow,
            signing_text=mutations["alternate identity"],
        )
        self.assertEqual(result.returncode, 1)
        self.assertIn("Different Developer", result.stderr)

    def test_dependency_roots_xcconfig_is_pinned_and_config_files_are_bound(self) -> None:
        module = load_guard_module()
        project = (REPOSITORY_ROOT / "MacScope/project.yml").read_text(encoding="utf-8")
        dependency = (REPOSITORY_ROOT / "MacScope/DependencyRoots.xcconfig").read_text(
            encoding="utf-8"
        )
        self.assertEqual(module.validate_dependency_roots_config(project, dependency), [])
        mutations = {
            "nonempty SLEIGH root": (
                project,
                dependency.replace(
                    "MACSCOPE_SLEIGH_MATERIALIZATION_ROOT =",
                    "MACSCOPE_SLEIGH_MATERIALIZATION_ROOT = /tmp/unsealed",
                ),
            ),
            "nonempty MachOKit root": (
                project,
                dependency.replace(
                    "MACSCOPE_MACHOKIT_MATERIALIZATION_ROOT =",
                    "MACSCOPE_MACHOKIT_MATERIALIZATION_ROOT = /tmp/unsealed",
                ),
            ),
            "nonempty Ghostty surface source": (
                project,
                dependency.replace(
                    "MACSCOPE_GHOSTTY_SURFACE_SOURCE_DIR =",
                    "MACSCOPE_GHOSTTY_SURFACE_SOURCE_DIR = /tmp/unsealed",
                ),
            ),
            "nonempty Ghostty surface artifact": (
                project,
                dependency.replace(
                    "MACSCOPE_GHOSTTY_SURFACE_ARTIFACT_ROOT =",
                    "MACSCOPE_GHOSTTY_SURFACE_ARTIFACT_ROOT = /tmp/unsealed",
                ),
            ),
            "enabled Ghostty surface": (
                project,
                dependency.replace(
                    "MACSCOPE_GHOSTTY_SURFACE_ENABLED =",
                    "MACSCOPE_GHOSTTY_SURFACE_ENABLED = MACSCOPE_FULL_GHOSTTY_SURFACE",
                ),
            ),
            "sensitive setting": (project, dependency + "CODE_SIGN_IDENTITY = -\n"),
            "second optional include": (
                project,
                dependency + '#include? "Arbitrary.local.xcconfig"\n',
            ),
            "optional signing include": (
                project,
                dependency.replace(
                    '#include "SigningIdentity.xcconfig"',
                    '#include? "SigningIdentity.xcconfig"',
                ),
            ),
            "missing Release binding": (
                project.replace("  Release: DependencyRoots.xcconfig\n", ""),
                dependency,
            ),
        }
        for name, (project_text, dependency_text) in mutations.items():
            with self.subTest(name=name):
                errors = module.validate_dependency_roots_config(
                    project_text, dependency_text
                )
                self.assertNotEqual(errors, [])

    def test_ci_enforces_xcode_27_on_pull_requests_and_main(self) -> None:
        workflow_text = (
            REPOSITORY_ROOT / ".github" / "workflows" / "ci.yml"
        ).read_text(encoding="utf-8")

        self.assertEqual(workflow_text.count("  workflow_dispatch:"), 1)
        # D11: native CI no longer runs on pull requests (lane starvation).
        self.assertEqual(workflow_text.count("  pull_request:"), 0)
        # D11: no per-merge native run; dispatch and the nightly schedule only.
        self.assertEqual(workflow_text.count("  push:"), 0)
        self.assertIn(
            "    runs-on: [self-hosted, macOS, ARM64, xcode-27]",
            workflow_text,
        )
        self.assertIn(
            "      DEVELOPER_DIR: /Applications/Xcode.app/Contents/Developer",
            workflow_text,
        )
        self.assertIn("./Scripts/qualify_local_private_build.sh \\", workflow_text)
        self.assertIn(
            "--integration-ref refs/remotes/origin/ci-event \\", workflow_text
        )
        self.assertNotIn("--materialize-dependencies", workflow_text)
        self.assertIn("${MACSCOPE_CI_SELECTION} \\", workflow_text)
        self.assertIn("Scripts/ci/affected_selectors.py", workflow_text)
        self.assertNotIn("--no-verification-reuse", workflow_text)
        self.assertIn("--signing development", workflow_text)

    def test_ci_requires_project_declared_xcodegen_minimum(self) -> None:
        workflow_text = (
            REPOSITORY_ROOT / ".github" / "workflows" / "ci.yml"
        ).read_text(encoding="utf-8")

        bootstrap_text = (
            REPOSITORY_ROOT / "Scripts" / "bootstrap.sh"
        ).read_text(encoding="utf-8")
        self.assertNotIn("brew install xcodegen", workflow_text)
        self.assertNotIn('required_xcodegen_version="2.45.4"', workflow_text)
        self.assertIn("source \"${SCRIPT_DIR}/xcode27_env.sh\"", bootstrap_text)
        self.assertIn('MINIMUM_XCODEGEN_VERSION="$(awk ', bootstrap_text)
        self.assertIn(
            'XCODEGEN="${MACSCOPE_XCODEGEN:-${REPO_ROOT}/ThirdParty/XcodeGen/bin/xcodegen}"',
            bootstrap_text,
        )
        self.assertIn('FOUND_VERSION="$("${XCODEGEN}" version ', bootstrap_text)
        self.assertIn("installed >= minimum", bootstrap_text)
        self.assertIn("satisfies minimum", bootstrap_text)

    def test_app_debug_disables_debug_dylibs_without_changing_signing_policy(self) -> None:
        module = load_guard_module()
        project_text = (REPOSITORY_ROOT / "MacScope" / "project.yml").read_text(
            encoding="utf-8"
        )
        settings = module.parse_scalar_mapping(project_text)

        self.assertEqual(
            {
                path: value
                for path, value in settings.items()
                if path[-1] == "ENABLE_DEBUG_DYLIB"
            },
            {
                (
                    "targets", "MacScopeApp", "settings", "configs", "Debug",
                    "ENABLE_DEBUG_DYLIB",
                ): "NO"
            },
        )
        self.assertEqual(
            settings[("settings", "configs", "Debug", "SWIFT_OPTIMIZATION_LEVEL")],
            "-Onone",
        )
        for configuration in ("Debug", "Release"):
            self.assertEqual(
                settings[(
                    "settings", "configs", configuration,
                    "CODE_SIGN_INJECT_BASE_ENTITLEMENTS",
                )],
                "YES",
            )
        self.assertEqual(module.validate_project_settings(project_text), [])

    def test_rejects_each_unstable_local_signing_setting(self) -> None:
        project_text = (REPOSITORY_ROOT / "MacScope" / "project.yml").read_text(encoding="utf-8")
        workflow_text = (REPOSITORY_ROOT / ".github" / "workflows" / "ci.yml").read_text(encoding="utf-8")
        mutations = {
            "automatic signing": ("CODE_SIGN_STYLE: Manual", "CODE_SIGN_STYLE: Automatic"),
            "missing team": (
                'DEVELOPMENT_TEAM: "$(MACSCOPE_SIGNING_TEAM)"',
                "DEVELOPMENT_TEAM: ''",
            ),
            "ad-hoc identity": (
                'CODE_SIGN_IDENTITY: "$(MACSCOPE_SIGNING_IDENTITY)"',
                "CODE_SIGN_IDENTITY: -",
            ),
            "legacy provisioning profile": (
                'PROVISIONING_PROFILE: ""',
                "PROVISIONING_PROFILE: BAD-PROFILE-UUID",
            ),
            "named provisioning profile": (
                'PROVISIONING_PROFILE_SPECIFIER: ""',
                "PROVISIONING_PROFILE_SPECIFIER: Unexpected Profile",
            ),
            "disabled hardened runtime": ("ENABLE_HARDENED_RUNTIME: YES", "ENABLE_HARDENED_RUNTIME: NO"),
            "changed app identifier": (
                "        PRODUCT_BUNDLE_IDENTIFIER: org.macscope.app\n",
                "        PRODUCT_BUNDLE_IDENTIFIER: org.macscope.app.unstable\n",
            ),
        }

        for name, (accepted, rejected) in mutations.items():
            with self.subTest(name=name):
                self.assertEqual(project_text.count(accepted), 1)
                result = self.run_guard(project_text.replace(accepted, rejected, 1), workflow_text)
                self.assertNotEqual(result.returncode, 0, result.stdout)

        release_injection_block = (
            "    Release:\n"
            "      # The installed app is a local-development qualification artifact, not a\n"
            "      # distribution build. Keep the stable Apple Development identity and\n"
            "      # hardened runtime, but inject the standard development entitlement so\n"
            "      # Xcode LLDB/debugserver can prove installed-app launch/attach contracts.\n"
            "      CODE_SIGN_ENTITLEMENTS: \"\"\n"
            "      CODE_SIGN_INJECT_BASE_ENTITLEMENTS: YES"
        )
        rejected_release_injection_block = release_injection_block.replace(
            "CODE_SIGN_INJECT_BASE_ENTITLEMENTS: YES",
            "CODE_SIGN_INJECT_BASE_ENTITLEMENTS: NO",
        )
        self.assertIn(release_injection_block, project_text)
        result = self.run_guard(
            project_text.replace(
                release_injection_block,
                rejected_release_injection_block,
                1,
            ),
            workflow_text,
        )
        self.assertNotEqual(result.returncode, 0, result.stdout)

    def test_rejects_source_deployment_target_drift(self) -> None:
        module = load_guard_module()
        project_text = (REPOSITORY_ROOT / "MacScope" / "project.yml").read_text(
            encoding="utf-8"
        )

        errors = module.validate_project_settings(
            project_text.replace('"27.0"', '"26.4"')
        )

        self.assertTrue(any("MACOSX_DEPLOYMENT_TARGET" in error for error in errors), errors)
        self.assertTrue(any("deploymentTarget" in error for error in errors), errors)

    def test_rejects_source_release_entitlements_file(self) -> None:
        module = load_guard_module()
        project_text = (REPOSITORY_ROOT / "MacScope" / "project.yml").read_text(
            encoding="utf-8"
        )
        release_config = project_text.split("    Release:\n", 1)[1].split("targets:", 1)[0]
        mutated_release_config = release_config.replace(
            '      CODE_SIGN_ENTITLEMENTS: ""\n',
            '      CODE_SIGN_ENTITLEMENTS: Resources/Release.entitlements\n',
            1,
        )
        mutated = project_text.replace(release_config, mutated_release_config, 1)

        errors = module.validate_project_settings(mutated)

        self.assertTrue(any("CODE_SIGN_ENTITLEMENTS" in error for error in errors), errors)

    def test_rejects_target_release_entitlements_file(self) -> None:
        module = load_guard_module()
        project_text = (REPOSITORY_ROOT / "MacScope" / "project.yml").read_text(
            encoding="utf-8"
        )
        mutated = project_text.replace(
            "        ENABLE_TESTABILITY: YES",
            "        ENABLE_TESTABILITY: YES\n"
            "      configs:\n"
            "        Release:\n"
            "          CODE_SIGN_ENTITLEMENTS: Resources/Release.entitlements",
        )

        errors = module.validate_project_settings(mutated)

        self.assertTrue(any("CODE_SIGN_ENTITLEMENTS" in error for error in errors), errors)

    def test_rejects_analysis_worker_target_signing_overrides(self) -> None:
        module = load_guard_module()
        project_text = (REPOSITORY_ROOT / "MacScope" / "project.yml").read_text(
            encoding="utf-8"
        )
        mutated = project_text.replace(
            "      base:\n        PRODUCT_NAME: AnalysisWorkerXPCService",
            "      base:\n"
            "        CODE_SIGN_IDENTITY: -\n"
            "        DEVELOPMENT_TEAM: BADTEAM123\n"
            "        ENABLE_HARDENED_RUNTIME: NO\n"
            "        PRODUCT_NAME: AnalysisWorkerXPCService",
        )

        errors = module.validate_project_settings(mutated)

        self.assertTrue(
            any("AnalysisWorkerXPCService" in error and "CODE_SIGN_IDENTITY" in error for error in errors),
            errors,
        )
        self.assertTrue(any("DEVELOPMENT_TEAM" in error for error in errors), errors)
        self.assertTrue(any("ENABLE_HARDENED_RUNTIME" in error for error in errors), errors)

    def test_rejects_plugin_target_identity_and_signing_overrides(self) -> None:
        module = load_guard_module()
        project_text = (REPOSITORY_ROOT / "MacScope" / "project.yml").read_text(
            encoding="utf-8"
        )
        mutated = project_text.replace(
            "      base:\n        PRODUCT_NAME: PluginXPCService",
            "      base:\n"
            "        CODE_SIGN_IDENTITY: -\n"
            "        DEVELOPMENT_TEAM: BADTEAM123\n"
            "        ENABLE_HARDENED_RUNTIME: NO\n"
            "        PRODUCT_NAME: PluginXPCService",
        ).replace(
            "PRODUCT_BUNDLE_IDENTIFIER: org.macscope.app.PluginXPCService",
            "PRODUCT_BUNDLE_IDENTIFIER: org.macscope.app.UnstablePlugin",
        )

        errors = module.validate_project_settings(mutated)

        self.assertTrue(
            any("PluginXPCService" in error and "CODE_SIGN_IDENTITY" in error for error in errors),
            errors,
        )
        self.assertTrue(any("DEVELOPMENT_TEAM" in error for error in errors), errors)
        self.assertTrue(any("ENABLE_HARDENED_RUNTIME" in error for error in errors), errors)
        self.assertTrue(
            any("PluginXPCService" in error and "PRODUCT_BUNDLE_IDENTIFIER" in error for error in errors),
            errors,
        )

    def test_rejects_ai_worker_identity_plist_and_signing_overrides(self) -> None:
        module = load_guard_module()
        project_text = (REPOSITORY_ROOT / "MacScope" / "project.yml").read_text(
            encoding="utf-8"
        )
        mutated = project_text.replace(
            "      base:\n        PRODUCT_NAME: AIAgentWorkerXPCService",
            "      base:\n"
            "        CODE_SIGN_IDENTITY: -\n"
            "        PRODUCT_NAME: AIAgentWorkerXPCService",
        ).replace(
            "PRODUCT_BUNDLE_IDENTIFIER: org.macscope.app.AIAgentWorker",
            "PRODUCT_BUNDLE_IDENTIFIER: org.macscope.app.UnstableAIWorker",
        ).replace(
            "INFOPLIST_FILE: AIAgentWorkerService/Info.plist",
            "INFOPLIST_FILE: AIAgentWorkerService/Other.plist",
        )

        errors = module.validate_project_settings(mutated)

        self.assertTrue(
            any("AIAgentWorkerXPCService" in error and "CODE_SIGN_IDENTITY" in error for error in errors),
            errors,
        )
        self.assertTrue(
            any("AIAgentWorkerXPCService" in error and "PRODUCT_BUNDLE_IDENTIFIER" in error for error in errors),
            errors,
        )
        self.assertTrue(
            any("AIAgentWorkerXPCService" in error and "INFOPLIST_FILE" in error for error in errors),
            errors,
        )

    def test_rejects_nonempty_other_code_sign_flags_in_source_policy(self) -> None:
        module = load_guard_module()
        project_text = (REPOSITORY_ROOT / "MacScope" / "project.yml").read_text(
            encoding="utf-8"
        )
        without_explicit_empty = project_text.replace(
            '    OTHER_CODE_SIGN_FLAGS: ""\n', ""
        )
        mutated = without_explicit_empty.replace(
            "    ENABLE_HARDENED_RUNTIME: YES\n",
            "    ENABLE_HARDENED_RUNTIME: YES\n"
            "    OTHER_CODE_SIGN_FLAGS: --deep\n",
            1,
        )

        errors = module.validate_project_settings(mutated)

        self.assertTrue(any("OTHER_CODE_SIGN_FLAGS" in error for error in errors), errors)

    def test_parses_quoted_sensitive_keys_and_rejects_conditional_overrides(self) -> None:
        module = load_guard_module()
        parsed = module.parse_scalar_mapping(
            'settings:\n  base:\n    "CODE_SIGN_IDENTITY": "-"\n'
        )
        self.assertEqual(
            parsed[("settings", "base", "CODE_SIGN_IDENTITY")],
            "-",
        )

        project_text = (REPOSITORY_ROOT / "MacScope" / "project.yml").read_text(
            encoding="utf-8"
        )
        mutated = project_text.replace(
            '    CODE_SIGN_IDENTITY: "$(MACSCOPE_SIGNING_IDENTITY)"\n',
            '    CODE_SIGN_IDENTITY: "$(MACSCOPE_SIGNING_IDENTITY)"\n'
            '    "CODE_SIGN_IDENTITY[sdk=macosx*]": '
            '"$(MACSCOPE_SIGNING_IDENTITY)"\n',
            1,
        )

        errors = module.validate_project_settings(mutated)

        self.assertTrue(
            any("conditional" in error and "CODE_SIGN_IDENTITY" in error for error in errors),
            errors,
        )

    def test_source_policy_protects_plists_and_per_configuration_settings(self) -> None:
        module = load_guard_module()
        project_text = (REPOSITORY_ROOT / "MacScope" / "project.yml").read_text(
            encoding="utf-8"
        )
        if "    Debug:\n" not in project_text:
            project_text = project_text.replace(
                "  configs:\n    Release:\n",
                "  configs:\n"
                "    Debug:\n"
                '      CODE_SIGN_ENTITLEMENTS: ""\n'
                "      CODE_SIGN_INJECT_BASE_ENTITLEMENTS: YES\n"
                "    Release:\n",
                1,
            )
        if '      CODE_SIGN_ENTITLEMENTS: ""\n' not in project_text.split(
            "    Release:\n", 1
        )[1]:
            project_text = project_text.replace(
                "    Release:\n",
                "    Release:\n      CODE_SIGN_ENTITLEMENTS: \"\"\n",
                1,
            )

        mutations = {
            "app plist path": (
                "        INFOPLIST_FILE: Resources/Info.plist",
                "        INFOPLIST_FILE: Resources/Other.plist",
                "INFOPLIST_FILE",
            ),
            "worker plist path": (
                "        INFOPLIST_FILE: AnalysisWorkerService/Info.plist",
                "        INFOPLIST_FILE: AnalysisWorkerService/Other.plist",
                "INFOPLIST_FILE",
            ),
            "authored plist generation": (
                "        GENERATE_INFOPLIST_FILE: NO",
                "        GENERATE_INFOPLIST_FILE: YES",
                "GENERATE_INFOPLIST_FILE",
            ),
            "debug base entitlement injection": (
                "    Debug:\n      CODE_SIGN_ENTITLEMENTS: \"\"\n"
                "      CODE_SIGN_INJECT_BASE_ENTITLEMENTS: YES",
                "    Debug:\n      CODE_SIGN_ENTITLEMENTS: \"\"\n"
                "      CODE_SIGN_INJECT_BASE_ENTITLEMENTS: NO",
                "CODE_SIGN_INJECT_BASE_ENTITLEMENTS",
            ),
            "debug authored entitlements": (
                '      CODE_SIGN_ENTITLEMENTS: ""',
                "      CODE_SIGN_ENTITLEMENTS: Resources/Debug.entitlements",
                "CODE_SIGN_ENTITLEMENTS",
            ),
            "debug optimization level": (
                '      SWIFT_OPTIMIZATION_LEVEL: "-Onone"',
                '      SWIFT_OPTIMIZATION_LEVEL: "-O"',
                "SWIFT_OPTIMIZATION_LEVEL",
            ),
        }
        for name, (accepted, rejected, expected_error) in mutations.items():
            with self.subTest(name=name):
                self.assertIn(accepted, project_text)
                errors = module.validate_project_settings(
                    project_text.replace(accepted, rejected, 1)
                )
                self.assertTrue(
                    any(expected_error in error for error in errors),
                    errors,
                )

        app_override = project_text.replace(
            "        ENABLE_TESTABILITY: YES",
            "        ENABLE_TESTABILITY: YES\n"
            "      configs:\n"
            "        Release:\n"
            "          PRODUCT_BUNDLE_IDENTIFIER: org.macscope.app.unstable",
            1,
        )
        worker_override = project_text.replace(
            "        SKIP_INSTALL: YES\n  CoreTests:",
            "        SKIP_INSTALL: YES\n"
            "      configs:\n"
            "        Debug:\n"
            "          PRODUCT_BUNDLE_IDENTIFIER: org.macscope.app.OtherWorker\n"
            "  CoreTests:",
            1,
        )
        for mutated in (app_override, worker_override):
            errors = module.validate_project_settings(mutated)
            self.assertTrue(
                any("PRODUCT_BUNDLE_IDENTIFIER" in error for error in errors),
                errors,
            )

    def test_ci_requires_certificate_backed_development_signing(self) -> None:
        module = load_guard_module()
        workflow_text = (REPOSITORY_ROOT / ".github" / "workflows" / "ci.yml").read_text(encoding="utf-8")
        self.assertEqual(module.validate_ci_override(workflow_text), [])
        self.assertNotEqual(
            module.validate_ci_override(
                workflow_text.replace(
                    "--signing development",
                    "--signing isolated-ci",
                    1,
                )
            ),
            [],
        )

    def test_ci_skips_release_candidate_only_on_the_nightly_schedule(self) -> None:
        module = load_guard_module()
        workflow_text = (REPOSITORY_ROOT / ".github" / "workflows" / "ci.yml").read_text(encoding="utf-8")
        run_line = '            --release-candidate "$MACSCOPE_RELEASE_CANDIDATE" \\\n'
        environment = module.CI_RELEASE_CANDIDATE_ENVIRONMENT_LINE
        self.assertEqual(workflow_text.count(run_line), 1)
        self.assertEqual(workflow_text.splitlines().count(environment), 1)
        self.assertEqual(module.validate_ci_override(workflow_text), [])
        # Without the option the qualifier always builds the Release candidate.
        self.assertEqual(
            module.validate_ci_override(
                workflow_text.replace(run_line, "").replace(environment + "\n", "")
            ),
            [],
        )
        mutations = {
            "literal skip": workflow_text.replace(
                run_line, "            --release-candidate skip \\\n"
            ),
            "skips dispatch": workflow_text.replace(
                "MACSCOPE_RELEASE_CANDIDATE: ${{ github.event_name == 'schedule'",
                "MACSCOPE_RELEASE_CANDIDATE: ${{ github.event_name != 'schedule'",
            ),
            "unconditional skip": workflow_text.replace(
                environment, "      MACSCOPE_RELEASE_CANDIDATE: skip"
            ),
            "step override": workflow_text.replace(
                "      - name: Build and test\n",
                "      - name: Override\n        run: echo MACSCOPE_RELEASE_CANDIDATE=skip >> \"$GITHUB_ENV\"\n"
                "      - name: Build and test\n",
            ),
            "duplicate option": workflow_text.replace(run_line, run_line + run_line),
        }
        for name, mutated in mutations.items():
            with self.subTest(name=name):
                self.assertNotEqual(mutated, workflow_text)
                self.assertNotEqual(module.validate_ci_override(mutated), [])

    def test_optional_isolated_ci_signing_branch_remains_fail_closed(self) -> None:
        module = load_guard_module()
        workflow_text = (
            REPOSITORY_ROOT / ".github" / "workflows" / "ci.yml"
        ).read_text(encoding="utf-8")
        qualifier_text = (
            REPOSITORY_ROOT / "Scripts" / "qualify_local_private_build.sh"
        ).read_text(encoding="utf-8")
        mutations = {
            "manual style": ("CODE_SIGN_STYLE=Manual", "CODE_SIGN_STYLE=Automatic"),
            "ad-hoc identity": ("CODE_SIGN_IDENTITY=-", "CODE_SIGN_IDENTITY=UNEXPECTED"),
            "empty team": ("DEVELOPMENT_TEAM=", "DEVELOPMENT_TEAM=TEAM000000"),
            "hardened runtime": (
                "ENABLE_HARDENED_RUNTIME=YES",
                "ENABLE_HARDENED_RUNTIME=NO",
            ),
        }

        for name, (accepted, rejected) in mutations.items():
            with self.subTest(name=name):
                self.assertEqual(qualifier_text.count(accepted), 1)
                self.assertNotEqual(
                    module.validate_ci_override(
                        workflow_text,
                        qualifier_text.replace(accepted, rejected, 1),
                    ),
                    [],
                )

    def test_ci_qualification_work_root_is_one_persistent_warm_root(self) -> None:
        # D9: CI keeps one warm run root; DerivedData is keyed by
        # toolchain/project identity (Scripts/ci/retained_product_identity.py).
        module = load_guard_module()
        workflow_text = (
            REPOSITORY_ROOT / ".github" / "workflows" / "ci.yml"
        ).read_text(encoding="utf-8")
        persistent = "macscope-qualification-nightly"
        self.assertEqual(workflow_text.count(persistent), 1)
        self.assertEqual(workflow_text.count("--persistent-run nightly \\"), 1)
        for other_root in ("macscope-qualification", "macscope-qualification-${{ github.run_id }}"):
            with self.subTest(other_root=other_root):
                self.assertNotEqual(
                    module.validate_ci_override(workflow_text.replace(persistent, other_root, 1)),
                    [],
                )

    def test_main_workflows_finish_while_branch_runs_keep_latest_attempt(self) -> None:
        for name in ("ci.yml", "governance.yml"):
            workflow = (REPOSITORY_ROOT / ".github/workflows" / name).read_text()
            expression = "  cancel-in-progress: ${{ github.ref != 'refs/heads/main' }}"
            self.assertEqual(workflow.count(expression), 1, name)
            self.assertIn("${{ github.ref }}", workflow)
            self.assertNotIn("  cancel-in-progress: true", workflow)

    def test_ci_retains_qualification_source_and_products_outside_runner_temp(self) -> None:
        module = load_guard_module()
        workflow = (REPOSITORY_ROOT / ".github/workflows/ci.yml").read_text()
        root = 'echo "MACSCOPE_CI_QUALIFICATION_ROOT=$MACSCOPE_WORK_ROOT/MacScopeCIQualificationRuns"'
        self.assertEqual(module.validate_ci_override(workflow), [])
        self.assertEqual(workflow.count(root), 1)
        self.assertEqual(workflow.count('$MACSCOPE_CI_QUALIFICATION_ROOT/$MACSCOPE_QUALIFICATION_WORK_ROOT_NAME'), 4)
        for name in ("TestResults.xcresult", "COVERAGE.json", "QUALIFICATION_INPUTS.json"):
            self.assertIn('${{ env.MACSCOPE_CI_QUALIFICATION_ROOT }}/${{ env.MACSCOPE_QUALIFICATION_WORK_ROOT_NAME }}/runs/**/' + name, workflow)
        self.assertNotIn('$RUNNER_TEMP/$MACSCOPE_QUALIFICATION_WORK_ROOT_NAME', workflow)
        self.assertNotEqual(module.validate_ci_override(workflow.replace(root, "MACSCOPE_CI_QUALIFICATION_ROOT: /tmp/qualification")), [])

    def test_ci_runner_root_exports_require_guard_and_exact_single_assignments(self) -> None:
        module = load_guard_module()
        workflow = (REPOSITORY_ROOT / ".github/workflows/ci.yml").read_text()
        self.assertEqual(module.validate_ci_override(workflow), [])
        lines = [
            line for line in workflow.splitlines()
            if ': "${MACSCOPE_WORK_ROOT:?' in line
            or ('echo "MACSCOPE_' in line and '=$MACSCOPE_WORK_ROOT/' in line)
        ]
        self.assertEqual(len(lines), 5)
        for line in lines:
            for replacement in ("", line + "\n" + line,
                                line.replace("MACSCOPE_WORK_ROOT", "OTHER_WORK_ROOT")):
                with self.subTest(line=line, replacement=replacement):
                    self.assertNotEqual(
                        module.validate_ci_override(workflow.replace(line, replacement)), [])
        self.assertNotEqual(module.validate_ci_override(
            workflow.replace('} >> "$GITHUB_ENV"', '} >> "/tmp/elsewhere"')), [])

    def test_rejects_ci_override_in_an_unrelated_xcodebuild_command(self) -> None:
        module = load_guard_module()
        workflow_text = """\
run: |
  xcodebuild \\
    -project MacScope/MacScope.xcodeproj \\
    -scheme MacScopeApp \\
    test
  xcodebuild \\
    CODE_SIGN_STYLE=Manual \\
    CODE_SIGN_IDENTITY=- \\
    DEVELOPMENT_TEAM= \\
    -version
"""

        self.assertNotEqual(module.validate_ci_override(workflow_text), [])

    def test_rejects_ci_override_in_a_nonexecuting_shell_block(self) -> None:
        module = load_guard_module()
        workflow_text = """\
steps:
  - name: Build and test
    run: |
      if false; then
        xcodebuild \\
          -project MacScope/MacScope.xcodeproj \\
          -scheme MacScopeApp \\
          AD_HOC_CODE_SIGNING_ALLOWED=YES \\
          CODE_SIGN_STYLE=Manual \\
          CODE_SIGN_IDENTITY=- \\
          DEVELOPMENT_TEAM= \\
          test
      fi
      xcodebuild \\
        -project MacScope/MacScope.xcodeproj \\
        -scheme MacScopeApp \\
        test
"""

        self.assertNotEqual(module.validate_ci_override(workflow_text), [])

    def test_rejects_ci_override_outside_live_test_job_or_on_disabled_step(self) -> None:
        module = load_guard_module()
        command = """\
          xcodebuild \\
            -project MacScope/MacScope.xcodeproj \\
            -scheme MacScopeApp \\
            AD_HOC_CODE_SIGNING_ALLOWED=YES \\
            CODE_SIGN_STYLE=Manual \\
            CODE_SIGN_IDENTITY=- \\
            DEVELOPMENT_TEAM= \\
            test > xcodebuild.log 2>&1 || { tail -400 xcodebuild.log; exit 1; }
"""
        alternate_job = f"""\
jobs:
  test:
    steps:
      - name: Checkout
        run: true
  disabled:
    if: false
    steps:
      - name: Build and test
        run: |
{command}"""
        disabled_step = f"""\
jobs:
  test:
    steps:
      - name: Build and test
        if: false
        run: |
{command}"""

        self.assertNotEqual(module.validate_ci_override(alternate_job), [])
        self.assertNotEqual(module.validate_ci_override(disabled_step), [])

    def test_bootstrap_runs_signing_guard_before_project_generation(self) -> None:
        bootstrap = (REPOSITORY_ROOT / "Scripts" / "bootstrap.sh").read_text(encoding="utf-8")

        guard_offset = bootstrap.find("check_local_signing_policy.py")
        generation_offset = bootstrap.find("xcodegen generate")
        effective_guard_offset = bootstrap.find("--xcodeproj")
        self.assertGreaterEqual(guard_offset, 0)
        self.assertGreater(generation_offset, guard_offset)
        self.assertGreater(effective_guard_offset, generation_offset)

    def test_generated_project_freshness_stamp_round_trip_and_staleness(self) -> None:
        module = load_guard_module()
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            project = make_generated_project_freshness_fixture(root)

            stamp = module.record_generated_project_freshness(project)

            self.assertEqual(module.validate_generated_project_freshness(project), [])
            self.assertEqual(
                module.PROJECT_FRESHNESS_INPUTS,
                (
                    ("MacScope/project.yml", "project.yml"),
                    (
                        "MacScope/DependencyRoots.xcconfig",
                        "DependencyRoots.xcconfig",
                    ),
                    (
                        "MacScope/SigningIdentity.xcconfig",
                        "SigningIdentity.xcconfig",
                    ),
                    (
                        "MacScope/MacScope.xcodeproj/project.xcproj",
                        "MacScope.xcodeproj/project.xcproj",
                    ),
                    (
                        "ThirdParty/SleighNative/PATCHED_RESOURCES.json",
                        "../ThirdParty/SleighNative/PATCHED_RESOURCES.json",
                    ),
                ),
            )
            self.assertEqual(stamp.stat().st_size, module.PROJECT_FRESHNESS_STAMP_SIZE)
            self.assertIsNotNone(
                module.PROJECT_FRESHNESS_STAMP_PATTERN.fullmatch(stamp.read_bytes())
            )
            for label, path in module.generated_project_freshness_inputs(project):
                with self.subTest(label=label):
                    original = path.read_bytes()
                    path.write_bytes(original + b"// mutation\n")
                    errors = module.validate_generated_project_freshness(project)
                    self.assertTrue(any(label in error for error in errors), errors)
                    path.write_bytes(original)
                    module.record_generated_project_freshness(project)

    def test_generated_project_freshness_tracks_folder_source_paths_not_contents(
        self,
    ) -> None:
        module = load_guard_module()
        for use_git in (True, False):
            with self.subTest(use_git=use_git), tempfile.TemporaryDirectory() as temporary_directory:
                root = Path(temporary_directory)
                project = make_generated_project_freshness_fixture(root)
                support = project.parent / "Tests" / "CoreTests" / "Support"
                support.mkdir(parents=True)
                existing = support / "Existing.swift"
                existing.write_text("let existing = 1\n", encoding="utf-8")
                if use_git:
                    subprocess.run(
                        ["/usr/bin/git", "init", "-q", str(root)], check=True
                    )
                    (root / ".gitignore").write_text(
                        "MacScope/MacScope.xcodeproj/\n", encoding="utf-8"
                    )
                    subprocess.run(
                        ["/usr/bin/git", "-C", str(root), "add", "-A"], check=True
                    )
                module.record_generated_project_freshness(project)
                self.assertEqual(module.validate_generated_project_freshness(project), [])

                # A content edit to an existing source file keeps the project fresh.
                existing.write_text("let existing = 2\n", encoding="utf-8")
                self.assertEqual(module.validate_generated_project_freshness(project), [])

                # A file arriving in a folder source (as by git merge) makes it stale.
                added = support / "TestSourceRoot.swift"
                added.write_text("enum TestSourceRoot {}\n", encoding="utf-8")
                if use_git:
                    subprocess.run(
                        ["/usr/bin/git", "-C", str(root), "add", "-A"], check=True
                    )
                errors = module.validate_generated_project_freshness(project)
                self.assertTrue(
                    any(module.PROJECT_FRESHNESS_SOURCE_PATHS_LABEL in error for error in errors),
                    errors,
                )

                # Removing it again restores the recorded path list; a rename does not.
                renamed = support / "Renamed.swift"
                added.rename(renamed)
                if use_git:
                    subprocess.run(
                        ["/usr/bin/git", "-C", str(root), "add", "-A"], check=True
                    )
                self.assertNotEqual(module.validate_generated_project_freshness(project), [])
                renamed.unlink()
                if use_git:
                    subprocess.run(
                        ["/usr/bin/git", "-C", str(root), "add", "-A"], check=True
                    )
                self.assertEqual(module.validate_generated_project_freshness(project), [])

    def test_record_refuses_when_source_paths_changed_during_generation(self) -> None:
        module = load_guard_module()
        with tempfile.TemporaryDirectory() as temporary_directory:
            project = make_generated_project_freshness_fixture(Path(temporary_directory))
            before = module.generated_project_source_paths_digest(project)
            module.record_generated_project_freshness(project, before)
            self.assertEqual(module.validate_generated_project_freshness(project), [])

            # A file created after the pre-generation capture (while XcodeGen ran).
            support = project.parent / "Tests" / "CoreTests"
            support.mkdir(parents=True)
            (support / "AddedDuringGeneration.swift").write_text("enum A {}\n", encoding="utf-8")
            with self.assertRaises(ValueError):
                module.record_generated_project_freshness(project, before)
            self.assertFalse(module.generated_project_freshness_stamp(project).exists())

            bootstrap = (REPOSITORY_ROOT / "Scripts" / "bootstrap.sh").read_text(encoding="utf-8")
            capture = bootstrap.find("--print-source-paths-digest")
            generation = bootstrap.find("generate_xcode_json_project.py", capture)
            check = bootstrap.find("--expected-source-paths-digest", generation)
            self.assertGreaterEqual(capture, 0)
            self.assertGreater(generation, capture)
            self.assertGreater(check, generation)

    def test_generated_project_freshness_rejects_json_byte_drift(
        self,
    ) -> None:
        module = load_guard_module()
        with tempfile.TemporaryDirectory() as temporary_directory:
            project = make_generated_project_freshness_fixture(Path(temporary_directory))
            module.record_generated_project_freshness(project)
            pbxproj = project.parent / "MacScope.xcodeproj/project.xcproj"
            pbxproj.write_text("// hand edited\n", encoding="utf-8")
            errors = module.validate_generated_project_freshness(project)
            self.assertTrue(any("project.xcproj" in error for error in errors), errors)

    def test_generated_project_freshness_rejects_missing_malformed_and_symlink_stamp(self) -> None:
        module = load_guard_module()
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            project = make_generated_project_freshness_fixture(root)
            stamp = module.generated_project_freshness_stamp(project)

            self.assertNotEqual(module.validate_generated_project_freshness(project), [])
            stamp.write_text("not-a-digest\n", encoding="ascii")
            self.assertNotEqual(module.validate_generated_project_freshness(project), [])
            stamp.write_text("0" * 64 + "\n", encoding="ascii")
            self.assertNotEqual(module.validate_generated_project_freshness(project), [])
            stamp.unlink()
            target = root / "foreign-stamp"
            target.write_text("0" * 64 + "\n", encoding="ascii")
            stamp.symlink_to(target)
            self.assertNotEqual(module.validate_generated_project_freshness(project), [])

    def test_build_environment_freshness_failure_names_bootstrap_fix(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            project = root / "MacScope" / "project.yml"
            project.parent.mkdir(parents=True)
            project.write_text("name: stale\n", encoding="utf-8")
            result = subprocess.run(
                [
                    "/usr/bin/python3",
                    str(GUARD),
                    "--project-yml",
                    str(project),
                    "--build-environment",
                    "--target",
                    "MacScopeApp",
                ],
                check=False,
                capture_output=True,
                text=True,
            )

            self.assertEqual(result.returncode, 1)
            self.assertIn("generated MacScope.xcodeproj", result.stderr)
            self.assertIn("./Scripts/bootstrap.sh", result.stderr)

    def test_bootstrap_invalidates_then_records_freshness_after_scheme_check(self) -> None:
        bootstrap = (REPOSITORY_ROOT / "Scripts" / "bootstrap.sh").read_text(
            encoding="utf-8"
        )

        invalidation = bootstrap.find('/bin/rm -f "${PROJECT_FRESHNESS_STAMP}"')
        generation = bootstrap.find("xcodegen generate", invalidation)
        scheme_check = bootstrap.find("xcodebuild \\", generation)
        recording = bootstrap.find("--record-generated-project-freshness", scheme_check)
        self.assertGreaterEqual(invalidation, 0)
        self.assertGreater(generation, invalidation)
        self.assertGreater(scheme_check, generation)
        self.assertGreater(recording, scheme_check)

    def test_bootstrap_uses_focused_signing_validator_without_broad_test_modules(self) -> None:
        bootstrap = (REPOSITORY_ROOT / "Scripts" / "bootstrap.sh").read_text(
            encoding="utf-8"
        )

        self.assertNotIn("unittest discover", bootstrap)
        validator_offset = bootstrap.find('"${SCRIPT_DIR}/check_local_signing_policy.py"')
        generation_offset = bootstrap.find("xcodegen generate")
        self.assertGreaterEqual(validator_offset, 0)
        self.assertGreater(generation_offset, validator_offset)

    def test_bootstrap_disables_repository_python_bytecode_caches_before_validation(self) -> None:
        bootstrap = (REPOSITORY_ROOT / "Scripts" / "bootstrap.sh").read_text(
            encoding="utf-8"
        )
        cache_guard_offset = bootstrap.find("export PYTHONDONTWRITEBYTECODE=1")
        first_python_offset = bootstrap.find("/usr/bin/python3")

        self.assertGreaterEqual(cache_guard_offset, 0)
        self.assertGreater(first_python_offset, cache_guard_offset)

    def test_rejects_ad_hoc_effective_target_settings(self) -> None:
        module = load_guard_module()
        validator = getattr(module, "validate_effective_settings", None)
        self.assertIsNotNone(validator)
        stable_settings = """\
Build settings for action build and target MacScopeApp:
    AD_HOC_CODE_SIGNING_ALLOWED = NO
    CODE_SIGNING_ALLOWED = YES
    CODE_SIGNING_REQUIRED = YES
    CODE_SIGN_STYLE = Manual
    CODE_SIGN_IDENTITY = Apple Development: MacScope Developer (CERT000000)
    PROVISIONING_PROFILE =
    PROVISIONING_PROFILE_SPECIFIER =
    DEVELOPMENT_TEAM = TEAM000000
    ENABLE_HARDENED_RUNTIME = YES
    MACOSX_DEPLOYMENT_TARGET = 27.0
    PRODUCT_BUNDLE_IDENTIFIER = org.macscope.app
    GENERATE_INFOPLIST_FILE = NO
    INFOPLIST_FILE = Resources/Info.plist
    CODE_SIGN_INJECT_BASE_ENTITLEMENTS = YES
"""

        self.assertEqual(validator(stable_settings, "Debug"), [])
        errors = validator(
            stable_settings.replace(
                "Apple Development: MacScope Developer (CERT000000)", "-"
            ),
            "Debug",
        )
        self.assertTrue(any("CODE_SIGN_IDENTITY" in error for error in errors), errors)

    def test_effective_settings_treat_omitted_profile_keys_as_profileless(self) -> None:
        module = load_guard_module()
        settings = """\
Build settings for action build and target MacScopeApp:
    AD_HOC_CODE_SIGNING_ALLOWED = NO
    CODE_SIGNING_ALLOWED = YES
    CODE_SIGNING_REQUIRED = YES
    CODE_SIGN_STYLE = Manual
    CODE_SIGN_IDENTITY = Apple Development: MacScope Developer (CERT000000)
    DEVELOPMENT_TEAM = TEAM000000
    ENABLE_HARDENED_RUNTIME = YES
    MACOSX_DEPLOYMENT_TARGET = 27.0
    PRODUCT_BUNDLE_IDENTIFIER = org.macscope.app
    GENERATE_INFOPLIST_FILE = NO
    INFOPLIST_FILE = Resources/Info.plist
    CODE_SIGN_INJECT_BASE_ENTITLEMENTS = YES
"""

        self.assertEqual(module.validate_effective_settings(settings, "Debug"), [])

    def test_effective_settings_validate_analysis_worker_target(self) -> None:
        module = load_guard_module()
        validator = getattr(module, "validate_effective_settings", None)
        self.assertIsNotNone(validator)
        self.assertIn("target", inspect.signature(validator).parameters)
        worker_settings = """\
Build settings for action build and target AnalysisWorkerXPCService:
    AD_HOC_CODE_SIGNING_ALLOWED = NO
    CODE_SIGNING_ALLOWED = YES
    CODE_SIGNING_REQUIRED = YES
    CODE_SIGN_STYLE = Manual
    CODE_SIGN_IDENTITY = Apple Development: MacScope Developer (CERT000000)
    PROVISIONING_PROFILE =
    PROVISIONING_PROFILE_SPECIFIER =
    DEVELOPMENT_TEAM = TEAM000000
    ENABLE_HARDENED_RUNTIME = YES
    MACOSX_DEPLOYMENT_TARGET = 27.0
    PRODUCT_BUNDLE_IDENTIFIER = org.macscope.app.AnalysisWorker
    GENERATE_INFOPLIST_FILE = NO
    INFOPLIST_FILE = AnalysisWorkerService/Info.plist
    CODE_SIGN_INJECT_BASE_ENTITLEMENTS = YES
"""

        self.assertEqual(
            validator(
                worker_settings,
                "Debug",
                "AnalysisWorkerXPCService",
            ),
            [],
        )
        errors = validator(
            worker_settings.replace(
                "Apple Development: MacScope Developer (CERT000000)", "-"
            ),
            "Debug",
            "AnalysisWorkerXPCService",
        )
        self.assertTrue(any("CODE_SIGN_IDENTITY" in error for error in errors), errors)

    @staticmethod
    def batch_settings(module, configuration):
        entries = []
        for target, identifier in module.EXPECTED_IDENTIFIERS_BY_TARGET.items():
            settings = dict(module.EXPECTED_EFFECTIVE_SETTINGS)
            settings.update(CONFIGURATION=configuration, PROJECT_FILE_PATH=str(Path("MacScope.xcproj").resolve()), PRODUCT_BUNDLE_IDENTIFIER=identifier,
                            GENERATE_INFOPLIST_FILE="NO", INFOPLIST_FILE=module.EXPECTED_INFO_PLISTS_BY_TARGET[target],
                            CODE_SIGN_INJECT_BASE_ENTITLEMENTS=module.EXPECTED_INJECT_BASE_ENTITLEMENTS_BY_CONFIGURATION[configuration])
            entries.append({"action": "build", "target": target, "buildSettings": settings})
        return entries

    def test_generated_project_validation_queries_all_configured_signed_targets(self) -> None:
        module = load_guard_module()
        calls = []
        def runner(command):
            calls.append(command)
            configuration = command[command.index("-configuration") + 1]
            return subprocess.CompletedProcess(command, 0, json.dumps(self.batch_settings(module, configuration)), "")
        self.assertEqual(module.validate_xcode_project(Path("MacScope.xcproj"), runner), [])
        self.assertEqual(len(calls), 2)
        self.assertEqual({c[c.index("-configuration")+1] for c in calls}, {"Debug", "Release"})
        self.assertTrue(all("-alltargets" in c and "-json" in c and "-target" not in c for c in calls))

    def test_batched_project_settings_reject_missing_duplicate_wrong_configuration_and_policy_drift(self):
        module = load_guard_module()
        def missing(entries): entries.pop()
        def duplicate(entries): entries.append(entries[0])
        def wrong_configuration(entries): entries[0]["buildSettings"]["CONFIGURATION"] = "Other"
        def wrong_identity(entries): entries[0]["buildSettings"]["CODE_SIGN_IDENTITY"] = "-"
        def wrong_runtime(entries): entries[0]["buildSettings"]["ENABLE_HARDENED_RUNTIME"] = "NO"
        def conditional(entries): entries[0]["buildSettings"]["CODE_SIGN_IDENTITY[sdk=macosx*]"] = "-"
        for mutate, expected in [(missing,"missing required"),(duplicate,"duplicate signed project target"),
                                 (wrong_configuration,"wrong CONFIGURATION"),(wrong_identity,"CODE_SIGN_IDENTITY"),
                                 (wrong_runtime,"ENABLE_HARDENED_RUNTIME"),(conditional,"conditional sensitive")]:
            with self.subTest(expected=expected):
                def runner(command):
                    configuration = command[command.index("-configuration")+1]
                    entries = self.batch_settings(module, configuration); mutate(entries)
                    return subprocess.CompletedProcess(command, 0, json.dumps(entries), "")
                errors = module.validate_xcode_project(Path("MacScope.xcproj"), runner)
                self.assertTrue(any(expected in error for error in errors), errors)

    def test_batched_project_settings_ignore_external_duplicates_but_reject_project_spoof(self):
        module = load_guard_module()
        for spoof_only in (False, True):
            def runner(command):
                configuration = command[command.index("-configuration")+1]
                entries = self.batch_settings(module, configuration)
                external = {"target": "SwiftAssemblyVendor", "buildSettings": {}}
                entries.extend([external, external])
                spoof = {"target": "MacScopeApp", "buildSettings": dict(entries[0]["buildSettings"], PROJECT_FILE_PATH="/external/Other.xcodeproj")}
                if spoof_only:
                    entries.pop(0)
                entries.extend([spoof, spoof])
                return subprocess.CompletedProcess(command, 0, json.dumps(entries), "")
            errors = module.validate_xcode_project(Path("MacScope.xcproj"), runner)
            if spoof_only:
                self.assertTrue(any("missing required signed target MacScopeApp" in error for error in errors), errors)
            else:
                self.assertEqual(errors, [])

    def test_batched_project_settings_reject_malformed_json_and_query_failure(self):
        module = load_guard_module()
        for output in ("not json", "{}", '[{"target":"MacScopeApp","target":"Other"}]',
                       '[{"target":"MacScopeApp","buildSettings":{"CONFIGURATION":42}}]'):
            with self.subTest(output=output):
                errors = module.validate_xcode_project(Path("MacScope.xcproj"),
                    lambda command: subprocess.CompletedProcess(command, 0, output, ""))
                self.assertEqual(len(errors), 2)
                self.assertTrue(all("invalid" in error for error in errors))
        errors = module.validate_xcode_project(Path("MacScope.xcproj"),
            lambda command: subprocess.CompletedProcess(command, 1, "", "failed query"))
        self.assertEqual(len(errors), 2)
        self.assertTrue(all("failed query" in error for error in errors))

    def test_effective_settings_reject_plist_entitlement_and_flag_drift(self) -> None:
        module = load_guard_module()
        stable_settings = """\
Build settings for action build and target MacScopeApp:
    AD_HOC_CODE_SIGNING_ALLOWED = NO
    CODE_SIGNING_ALLOWED = YES
    CODE_SIGNING_REQUIRED = YES
    CODE_SIGN_STYLE = Manual
    CODE_SIGN_IDENTITY = Apple Development: MacScope Developer (CERT000000)
    PROVISIONING_PROFILE =
    PROVISIONING_PROFILE_SPECIFIER =
    DEVELOPMENT_TEAM = TEAM000000
    ENABLE_HARDENED_RUNTIME = YES
    MACOSX_DEPLOYMENT_TARGET = 27.0
    PRODUCT_BUNDLE_IDENTIFIER = org.macscope.app
    GENERATE_INFOPLIST_FILE = NO
    INFOPLIST_FILE = Resources/Info.plist
    CODE_SIGN_INJECT_BASE_ENTITLEMENTS = YES
    CODE_SIGN_ENTITLEMENTS =
    OTHER_CODE_SIGN_FLAGS =
"""
        self.assertEqual(
            module.validate_effective_settings(stable_settings, "Debug"),
            [],
        )

        mutations = {
            "GENERATE_INFOPLIST_FILE": (
                "GENERATE_INFOPLIST_FILE = NO",
                "GENERATE_INFOPLIST_FILE = YES",
            ),
            "INFOPLIST_FILE": (
                "INFOPLIST_FILE = Resources/Info.plist",
                "INFOPLIST_FILE = Resources/Other.plist",
            ),
            "CODE_SIGN_INJECT_BASE_ENTITLEMENTS": (
                "CODE_SIGN_INJECT_BASE_ENTITLEMENTS = YES",
                "CODE_SIGN_INJECT_BASE_ENTITLEMENTS = NO",
            ),
            "CODE_SIGN_ENTITLEMENTS": (
                "CODE_SIGN_ENTITLEMENTS =\n",
                "CODE_SIGN_ENTITLEMENTS = Resources/Debug.entitlements\n",
            ),
            "OTHER_CODE_SIGN_FLAGS": (
                "OTHER_CODE_SIGN_FLAGS =\n",
                "OTHER_CODE_SIGN_FLAGS = --deep\n",
            ),
            "PROVISIONING_PROFILE": (
                "PROVISIONING_PROFILE =\n",
                "PROVISIONING_PROFILE = BAD-PROFILE-UUID\n",
            ),
            "PROVISIONING_PROFILE_SPECIFIER": (
                "PROVISIONING_PROFILE_SPECIFIER =\n",
                "PROVISIONING_PROFILE_SPECIFIER = Unexpected Profile\n",
            ),
        }
        for key, (accepted, rejected) in mutations.items():
            with self.subTest(key=key):
                errors = module.validate_effective_settings(
                    stable_settings.replace(accepted, rejected, 1),
                    "Debug",
                )
                self.assertTrue(any(key in error for error in errors), errors)

        conditional_settings = stable_settings + (
            "    CODE_SIGN_IDENTITY[sdk=macosx*] = -\n"
        )
        errors = module.validate_effective_settings(conditional_settings, "Debug")
        self.assertTrue(
            any("conditional" in error and "CODE_SIGN_IDENTITY" in error for error in errors),
            errors,
        )

    def test_release_effective_settings_require_enabled_base_entitlement_injection(self) -> None:
        module = load_guard_module()
        release_settings = """\
Build settings for action build and target MacScopeApp:
    AD_HOC_CODE_SIGNING_ALLOWED = NO
    CODE_SIGNING_ALLOWED = YES
    CODE_SIGNING_REQUIRED = YES
    CODE_SIGN_STYLE = Manual
    CODE_SIGN_IDENTITY = Apple Development: MacScope Developer (CERT000000)
    PROVISIONING_PROFILE =
    PROVISIONING_PROFILE_SPECIFIER =
    DEVELOPMENT_TEAM = TEAM000000
    ENABLE_HARDENED_RUNTIME = YES
    MACOSX_DEPLOYMENT_TARGET = 27.0
    PRODUCT_BUNDLE_IDENTIFIER = org.macscope.app
    CODE_SIGN_INJECT_BASE_ENTITLEMENTS = NO
"""

        errors = module.validate_effective_settings(release_settings, "Release")
        self.assertTrue(
            any("CODE_SIGN_INJECT_BASE_ENTITLEMENTS" in error for error in errors),
            errors,
        )

    def test_release_effective_settings_reject_nonempty_entitlements_file(self) -> None:
        module = load_guard_module()
        release_settings = """\
Build settings for action build and target MacScopeApp:
    AD_HOC_CODE_SIGNING_ALLOWED = NO
    CODE_SIGNING_ALLOWED = YES
    CODE_SIGNING_REQUIRED = YES
    CODE_SIGN_STYLE = Manual
    CODE_SIGN_IDENTITY = Apple Development: MacScope Developer (CERT000000)
    PROVISIONING_PROFILE =
    PROVISIONING_PROFILE_SPECIFIER =
    DEVELOPMENT_TEAM = TEAM000000
    ENABLE_HARDENED_RUNTIME = YES
    MACOSX_DEPLOYMENT_TARGET = 27.0
    PRODUCT_BUNDLE_IDENTIFIER = org.macscope.app
    CODE_SIGN_INJECT_BASE_ENTITLEMENTS = YES
    CODE_SIGN_ENTITLEMENTS = Resources/Release.entitlements
"""

        errors = module.validate_effective_settings(release_settings, "Release")

        self.assertTrue(any("CODE_SIGN_ENTITLEMENTS" in error for error in errors), errors)

    def test_rejects_local_ad_hoc_or_disabled_code_signing_environment(self) -> None:
        module = load_guard_module()
        validator = getattr(module, "validate_build_environment", None)
        self.assertIsNotNone(validator)
        environment = {
            "CONFIGURATION": "Debug",
            "AD_HOC_CODE_SIGNING_ALLOWED": "NO",
            "CODE_SIGNING_ALLOWED": "YES",
            "CODE_SIGNING_REQUIRED": "YES",
            "CODE_SIGN_STYLE": "Manual",
            "CODE_SIGN_IDENTITY": "Apple Development: MacScope Developer (CERT000000)",
            "PROVISIONING_PROFILE": "",
            "PROVISIONING_PROFILE_SPECIFIER": "",
            "DEVELOPMENT_TEAM": "TEAM000000",
            "ENABLE_HARDENED_RUNTIME": "YES",
            "MACOSX_DEPLOYMENT_TARGET": "27.0",
            "PRODUCT_BUNDLE_IDENTIFIER": "org.macscope.app",
            "GENERATE_INFOPLIST_FILE": "NO",
            "INFOPLIST_FILE": "Resources/Info.plist",
            "CODE_SIGN_INJECT_BASE_ENTITLEMENTS": "YES",
        }

        self.assertEqual(validator(environment), [])
        for key, rejected in {
            "AD_HOC_CODE_SIGNING_ALLOWED": "YES",
            "CODE_SIGNING_ALLOWED": "NO",
            "CODE_SIGNING_REQUIRED": "NO",
            "CODE_SIGN_IDENTITY": "-",
            "PROVISIONING_PROFILE": "BAD-PROFILE-UUID",
            "PROVISIONING_PROFILE_SPECIFIER": "Unexpected Profile",
        }.items():
            with self.subTest(key=key):
                mutated = dict(environment)
                mutated[key] = rejected
                errors = validator(mutated)
                self.assertTrue(any(key in error for error in errors), errors)

    def test_build_environment_treats_omitted_profile_keys_as_profileless(self) -> None:
        module = load_guard_module()
        environment = {
            "CONFIGURATION": "Debug",
            "AD_HOC_CODE_SIGNING_ALLOWED": "NO",
            "CODE_SIGNING_ALLOWED": "YES",
            "CODE_SIGNING_REQUIRED": "YES",
            "CODE_SIGN_STYLE": "Manual",
            "CODE_SIGN_IDENTITY": "Apple Development: MacScope Developer (CERT000000)",
            "DEVELOPMENT_TEAM": "TEAM000000",
            "ENABLE_HARDENED_RUNTIME": "YES",
            "MACOSX_DEPLOYMENT_TARGET": "27.0",
            "PRODUCT_BUNDLE_IDENTIFIER": "org.macscope.app",
            "GENERATE_INFOPLIST_FILE": "NO",
            "INFOPLIST_FILE": "Resources/Info.plist",
            "CODE_SIGN_INJECT_BASE_ENTITLEMENTS": "YES",
        }

        self.assertEqual(module.validate_build_environment(environment), [])

    def test_release_build_environment_rejects_nonempty_entitlements_file(self) -> None:
        module = load_guard_module()
        environment = {
            "CONFIGURATION": "Release",
            "AD_HOC_CODE_SIGNING_ALLOWED": "NO",
            "CODE_SIGNING_ALLOWED": "YES",
            "CODE_SIGNING_REQUIRED": "YES",
            "CODE_SIGN_STYLE": "Manual",
            "CODE_SIGN_IDENTITY": "Apple Development: MacScope Developer (CERT000000)",
            "PROVISIONING_PROFILE": "",
            "PROVISIONING_PROFILE_SPECIFIER": "",
            "DEVELOPMENT_TEAM": "TEAM000000",
            "ENABLE_HARDENED_RUNTIME": "YES",
            "MACOSX_DEPLOYMENT_TARGET": "27.0",
            "PRODUCT_BUNDLE_IDENTIFIER": "org.macscope.app",
            "GENERATE_INFOPLIST_FILE": "NO",
            "INFOPLIST_FILE": "Resources/Info.plist",
            "CODE_SIGN_INJECT_BASE_ENTITLEMENTS": "YES",
            "CODE_SIGN_ENTITLEMENTS": "Resources/Release.entitlements",
        }

        errors = module.validate_build_environment(environment)

        self.assertTrue(any("CODE_SIGN_ENTITLEMENTS" in error for error in errors), errors)

    def test_release_build_environment_rejects_native_decompiler_live_test_condition(self) -> None:
        module = load_guard_module()
        environment = {
            "CONFIGURATION": "Release",
            "AD_HOC_CODE_SIGNING_ALLOWED": "NO",
            "CODE_SIGNING_ALLOWED": "YES",
            "CODE_SIGNING_REQUIRED": "YES",
            "CODE_SIGN_STYLE": "Manual",
            "CODE_SIGN_IDENTITY": "Apple Development: MacScope Developer (CERT000000)",
            "PROVISIONING_PROFILE": "",
            "PROVISIONING_PROFILE_SPECIFIER": "",
            "DEVELOPMENT_TEAM": "TEAM000000",
            "ENABLE_HARDENED_RUNTIME": "YES",
            "MACOSX_DEPLOYMENT_TARGET": "27.0",
            "PRODUCT_BUNDLE_IDENTIFIER": "org.macscope.app",
            "GENERATE_INFOPLIST_FILE": "NO",
            "INFOPLIST_FILE": "Resources/Info.plist",
            "CODE_SIGN_INJECT_BASE_ENTITLEMENTS": "NO",
            "CODE_SIGN_ENTITLEMENTS": "",
            "MACSCOPE_NATIVE_DECOMPILER_LIVE_TEST_CONDITION": (
                "NATIVE_DECOMPILER_SIGNED_LIVE_TESTS"
            ),
        }

        errors = module.validate_build_environment(environment)

        self.assertTrue(
            any("MACSCOPE_NATIVE_DECOMPILER_LIVE_TEST_CONDITION" in error for error in errors),
            errors,
        )

        direct_condition = dict(environment)
        direct_condition["MACSCOPE_NATIVE_DECOMPILER_LIVE_TEST_CONDITION"] = ""
        direct_condition["SWIFT_ACTIVE_COMPILATION_CONDITIONS"] = (
            "MACSCOPE_NATIVE_DECOMPILER_LIVE_XPC_TESTING"
        )
        errors = module.validate_build_environment(direct_condition)
        self.assertTrue(
            any("SWIFT_ACTIVE_COMPILATION_CONDITIONS" in error for error in errors),
            errors,
        )

        direct_flag = dict(environment)
        direct_flag["MACSCOPE_NATIVE_DECOMPILER_LIVE_TEST_CONDITION"] = ""
        direct_flag["OTHER_SWIFT_FLAGS"] = (
            "-DMACSCOPE_NATIVE_DECOMPILER_LIVE_XPC_TESTING"
        )
        errors = module.validate_build_environment(direct_flag)
        self.assertTrue(any("OTHER_SWIFT_FLAGS" in error for error in errors), errors)

    def test_build_environment_is_target_aware_and_rejects_other_code_sign_flags(self) -> None:
        module = load_guard_module()
        validator = module.validate_build_environment
        self.assertIn("target", inspect.signature(validator).parameters)
        worker_environment = {
            "TARGET_NAME": "AnalysisWorkerXPCService",
            "CONFIGURATION": "Debug",
            "AD_HOC_CODE_SIGNING_ALLOWED": "NO",
            "CODE_SIGNING_ALLOWED": "YES",
            "CODE_SIGNING_REQUIRED": "YES",
            "CODE_SIGN_STYLE": "Manual",
            "CODE_SIGN_IDENTITY": "Apple Development: MacScope Developer (CERT000000)",
            "PROVISIONING_PROFILE": "",
            "PROVISIONING_PROFILE_SPECIFIER": "",
            "DEVELOPMENT_TEAM": "TEAM000000",
            "ENABLE_HARDENED_RUNTIME": "YES",
            "MACOSX_DEPLOYMENT_TARGET": "27.0",
            "PRODUCT_BUNDLE_IDENTIFIER": "org.macscope.app.AnalysisWorker",
            "GENERATE_INFOPLIST_FILE": "NO",
            "INFOPLIST_FILE": "AnalysisWorkerService/Info.plist",
            "CODE_SIGN_INJECT_BASE_ENTITLEMENTS": "YES",
            "CODE_SIGN_ENTITLEMENTS": "",
            "OTHER_CODE_SIGN_FLAGS": "",
        }

        self.assertEqual(
            validator(worker_environment, "AnalysisWorkerXPCService"),
            [],
        )
        for key, rejected in {
            "PRODUCT_BUNDLE_IDENTIFIER": "org.macscope.app",
            "OTHER_CODE_SIGN_FLAGS": "--deep",
            "PROVISIONING_PROFILE": "BAD-PROFILE-UUID",
            "PROVISIONING_PROFILE_SPECIFIER": "Unexpected Profile",
            "CODE_SIGN_IDENTITY[sdk=macosx*]": "-",
        }.items():
            with self.subTest(key=key):
                mutated = dict(worker_environment)
                mutated[key] = rejected
                errors = validator(mutated, "AnalysisWorkerXPCService")
                self.assertTrue(any(key in error for error in errors), errors)

        mismatched_target = dict(worker_environment)
        mismatched_target["TARGET_NAME"] = "MacScopeApp"
        errors = validator(mismatched_target, "AnalysisWorkerXPCService")
        self.assertTrue(any("TARGET_NAME" in error for error in errors), errors)

    def test_app_target_invokes_build_environment_guard(self) -> None:
        module = load_guard_module()
        project_text = (REPOSITORY_ROOT / "MacScope" / "project.yml").read_text(encoding="utf-8")

        self.assertEqual(module.validate_app_target_guard(project_text), [])

    def test_app_target_has_exact_final_release_provenance_phase(self) -> None:
        module = load_guard_module()
        validator = getattr(module, "validate_release_provenance_project_phase", None)
        self.assertIsNotNone(validator)
        project_text = (REPOSITORY_ROOT / "MacScope" / "project.yml").read_text(
            encoding="utf-8"
        )

        self.assertEqual(validator(project_text), [])
        mutations = {
            "dependency-skippable": project_text.replace(
                "      - name: Generate sealed Release build provenance\n"
                "        basedOnDependencyAnalysis: false",
                "      - name: Generate sealed Release build provenance\n"
                "        basedOnDependencyAnalysis: true",
                1,
            ),
            "wrong-output": project_text.replace(
                "MacScopeBuildProvenance.json",
                "UnsealedProvenance.json",
                1,
            ),
            "missing-sdk-build": project_text.replace(
                '            --sdk-build "$SDK_PRODUCT_BUILD_VERSION" \\\n',
                "",
                1,
            ),
            "missing-supported-configuration-guard": project_text.replace(
                '          if [ "$CONFIGURATION" != "Release" ] && [ "$CONFIGURATION" != "Debug" ]; then\n'
                "            exit 1\n"
                "          fi\n",
                "",
                1,
            ),
            "missing-native-live-test-condition": project_text.replace(
                '            --native-decompiler-live-test-condition '
                '"$MACSCOPE_NATIVE_DECOMPILER_LIVE_TEST_CONDITION" \\\n',
                "",
                1,
            ),
            "missing-ghostty-root": project_text.replace(
                '            --ghostty-source-dir "$SRCROOT/../ThirdParty/GhosttyVT/Source" \\\n',
                "",
                1,
            ),
            "missing-sleigh-root": project_text.replace(
                "            --sleigh-materialization-root "
                '"$MACSCOPE_SLEIGH_MATERIALIZATION_ROOT" \\\n',
                "",
                1,
            ),
            "missing-machokit-root": project_text.replace(
                "            --machokit-materialization-root "
                '"$MACSCOPE_MACHOKIT_MATERIALIZATION_ROOT" \\\n',
                "",
                1,
            ),
            "missing-analysis-worker-executable": project_text.replace(
                '            --analysis-worker-executable "$TARGET_BUILD_DIR/'
                '$CONTENTS_FOLDER_PATH/XPCServices/AnalysisWorkerXPCService.xpc/'
                'Contents/MacOS/AnalysisWorkerXPCService" \\\n',
                "",
                1,
            ),
            "missing-resolved-swift-conditions": project_text.replace(
                '            --swift-active-compilation-conditions '
                '"$SWIFT_ACTIVE_COMPILATION_CONDITIONS" \\\n',
                "",
                1,
            ),
            "missing-other-swift-flags": project_text.replace(
                '            --other-swift-flags "$OTHER_SWIFT_FLAGS" \\\n',
                "",
                1,
            ),
            "missing-native-golden-input": project_text.replace(
                '        inputFiles:\n'
                '          - "$(TARGET_BUILD_DIR)/$(CONTENTS_FOLDER_PATH)/XPCServices/'
                'NativeDecompilerXPCService.xpc/Contents/Resources/'
                'NativeDecompilerBridgeGolden.json"\n',
                "",
                1,
            ),
            "missing-native-golden-argument": project_text.replace(
                '            --native-decompiler-golden-result "$TARGET_BUILD_DIR/'
                '$CONTENTS_FOLDER_PATH/XPCServices/NativeDecompilerXPCService.xpc/'
                'Contents/Resources/NativeDecompilerBridgeGolden.json" \\\n',
                "",
                1,
            ),
            "undefined-swift-exec": project_text.replace(
                '"$DEVELOPER_DIR/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc"',
                '"$SWIFT_EXEC"',
                1,
            ),
        }
        supported_guard = "\n".join(module.RELEASE_PROVENANCE_GUARD_LINES) + "\n"
        for replacement in (
            '          if [ "$CONFIGURATION" != "Release" ]; then\n            exit 0\n          fi\n',
            '          if [ "$CONFIGURATION" != "Release" ]; then\n            exit 1\n          fi\n',
            '          if [ "$CONFIGURATION" = "Debug" ]; then\n            exit 0\n          fi\n',
            supported_guard.replace("exit 1", "exit 0"),
        ):
            mutated = project_text.replace(supported_guard, replacement, 1)
            with self.subTest(guard=replacement):
                self.assertNotEqual(mutated, project_text)
                self.assertNotEqual(validator(mutated), [])
        for name, mutated in mutations.items():
            with self.subTest(name=name):
                self.assertNotEqual(validator(mutated), [])

    def test_generated_app_target_keeps_provenance_after_copyfiles_and_last(self) -> None:
        module = load_guard_module()
        validator = getattr(module, "validate_generated_provenance_build_phase", None)
        self.assertIsNotNone(validator)
        generated = r'''\
/* Begin PBXCopyFilesBuildPhase section */
		AAAAAAAAAAAAAAAAAAAAAAAA /* CopyFiles */ = {
			isa = PBXCopyFilesBuildPhase;
			dstPath = "$(CONTENTS_FOLDER_PATH)/XPCServices";
		};
/* End PBXCopyFilesBuildPhase section */
/* Begin PBXNativeTarget section */
		CCCCCCCCCCCCCCCCCCCCCCCC /* MacScopeApp */ = {
			isa = PBXNativeTarget;
			buildPhases = (
				DDDDDDDDDDDDDDDDDDDDDDDD /* Sources */,
				AAAAAAAAAAAAAAAAAAAAAAAA /* CopyFiles */,
				BBBBBBBBBBBBBBBBBBBBBBBB /* Generate sealed Release build provenance */,
			);
			name = MacScopeApp;
		};
/* End PBXNativeTarget section */
/* Begin PBXShellScriptBuildPhase section */
		BBBBBBBBBBBBBBBBBBBBBBBB /* Generate sealed Release build provenance */ = {
			isa = PBXShellScriptBuildPhase;
			alwaysOutOfDate = 1;
			name = "Generate sealed Release build provenance";
			inputPaths = (
				"$(TARGET_BUILD_DIR)/$(CONTENTS_FOLDER_PATH)/XPCServices/NativeDecompilerXPCService.xpc/Contents/Resources/NativeDecompilerBridgeGolden.json",
				"$(TARGET_BUILD_DIR)/$(CONTENTS_FOLDER_PATH)/XPCServices/NativeDecompilerXPCService.xpc/Contents/Resources/NativeDecompilerPackage/MATERIALIZATION.json",
				"$(TARGET_BUILD_DIR)/$(CONTENTS_FOLDER_PATH)/XPCServices/NativeDecompilerXPCService.xpc/Contents/Resources/NativeDecompilerPackage/package",
				"$(TARGET_BUILD_DIR)/$(CONTENTS_FOLDER_PATH)/XPCServices/NativeDecompilerXPCService.xpc/Contents/Resources/NativeDecompilerPackage/package/lib/libdecomp.a",
				"$(TARGET_BUILD_DIR)/$(CONTENTS_FOLDER_PATH)/XPCServices/NativeDecompilerXPCService.xpc/Contents/Resources/NativeDecompilerPackage/package/lib/libsla.a",
				"$(TARGET_BUILD_DIR)/$(CONTENTS_FOLDER_PATH)/XPCServices/NativeDecompilerXPCService.xpc/Contents/Info.plist",
				"$(TARGET_BUILD_DIR)/$(CONTENTS_FOLDER_PATH)/XPCServices/NativeDecompilerXPCService.xpc/Contents/MacOS/NativeDecompilerXPCService",
				"$(TARGET_BUILD_DIR)/$(CONTENTS_FOLDER_PATH)/XPCServices/NativeDecompilerXPCService.xpc/Contents/_CodeSignature/CodeResources",
				"$(MACSCOPE_GHOSTTY_SURFACE_MANIFEST)",
				"$(MACSCOPE_GHOSTTY_SURFACE_STAGED_DESCRIPTOR)",
				"$(MACSCOPE_GHOSTTY_SURFACE_ARCHIVE)",
				"$(MACSCOPE_GHOSTTY_SURFACE_HEADER)",
				"$(MACSCOPE_GHOSTTY_SURFACE_MODULE_MAP)",
				"$(TARGET_BUILD_DIR)/$(CONTENTS_FOLDER_PATH)/XPCServices/AnalysisWorkerXPCService.xpc/Contents/MacOS/AnalysisWorkerXPCService",
				"$(MACSCOPE_MACHOKIT_MATERIALIZATION_ROOT)/MATERIALIZATION.json",
			);
			outputPaths = (
				"$(TARGET_BUILD_DIR)/$(UNLOCALIZED_RESOURCES_FOLDER_PATH)/MacScopeBuildProvenance.json",
			);
			shellScript = "if [ \"$CONFIGURATION\" != \"Release\" ] && [ \"$CONFIGURATION\" != \"Debug\" ]; then\nexit 1\nfi\n/usr/bin/python3 \"$SRCROOT/../Scripts/generate_release_build_provenance.py\" --repo-root \"$SRCROOT/..\" --project-yml \"$SRCROOT/project.yml\" --project-file-path \"$PROJECT_FILE_PATH\" --configuration \"$CONFIGURATION\" --ghostty-surface-manifest \"$MACSCOPE_GHOSTTY_SURFACE_MANIFEST\" --ghostty-surface-staged-root \"$MACSCOPE_GHOSTTY_SURFACE_STAGED_ROOT\" --machokit-materialization-root \"$MACSCOPE_MACHOKIT_MATERIALIZATION_ROOT\" --analysis-worker-executable \"$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/XPCServices/AnalysisWorkerXPCService.xpc/Contents/MacOS/AnalysisWorkerXPCService\" --native-decompiler-live-test-condition \"$MACSCOPE_NATIVE_DECOMPILER_LIVE_TEST_CONDITION\" --swift-active-compilation-conditions \"$SWIFT_ACTIVE_COMPILATION_CONDITIONS\" --other-swift-flags \"$OTHER_SWIFT_FLAGS\" --architectures \"$ARCHS\" --deployment-target \"$MACOSX_DEPLOYMENT_TARGET\" --sdk-name \"$SDK_NAME\" --sdk-version \"$SDK_VERSION\" --sdk-build \"$SDK_PRODUCT_BUILD_VERSION\" --developer-dir \"$DEVELOPER_DIR\" --swift-executable \"$DEVELOPER_DIR/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc\" --native-decompiler-golden-result \"$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/XPCServices/NativeDecompilerXPCService.xpc/Contents/Resources/NativeDecompilerBridgeGolden.json\" --output \"$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/MacScopeBuildProvenance.json\"\n";
		};
/* End PBXShellScriptBuildPhase section */
'''

        self.assertEqual(validator(generated), [])
        generated_with_two_xpc_copy_phases = generated.replace(
            "/* End PBXCopyFilesBuildPhase section */",
            '''\
		EEEEEEEEEEEEEEEEEEEEEEEE /* CopyAdditionalXPC */ = {
			isa = PBXCopyFilesBuildPhase;
			dstPath = "$(CONTENTS_FOLDER_PATH)/XPCServices";
		};
/* End PBXCopyFilesBuildPhase section */''',
        ).replace(
            "\t\t\t\tAAAAAAAAAAAAAAAAAAAAAAAA /* CopyFiles */,\n"
            "\t\t\t\tBBBBBBBBBBBBBBBBBBBBBBBB /* Generate sealed Release build provenance */,",
            "\t\t\t\tAAAAAAAAAAAAAAAAAAAAAAAA /* CopyFiles */,\n"
            "\t\t\t\tEEEEEEEEEEEEEEEEEEEEEEEE /* CopyAdditionalXPC */,\n"
            "\t\t\t\tBBBBBBBBBBBBBBBBBBBBBBBB /* Generate sealed Release build provenance */,",
        )
        self.assertEqual(validator(generated_with_two_xpc_copy_phases), [])
        guard = r'if [ \"$CONFIGURATION\" != \"Release\" ] && [ \"$CONFIGURATION\" != \"Debug\" ]; then\nexit 1\nfi\n'
        for replacement in (
            "",
            guard.replace("exit 1", "exit 0"),
            r'if [ \"$CONFIGURATION\" != \"Release\" ]; then\nexit 0\nfi\n',
            r'if [ \"$CONFIGURATION\" = \"Debug\" ]; then\nexit 0\nfi\n' + guard,
        ):
            mutated = generated.replace(guard, replacement, 1)
            with self.subTest(guard=replacement):
                self.assertNotEqual(mutated, generated)
                self.assertNotEqual(validator(mutated), [])
        mutations = {
            "before-copy": generated.replace(
                "\t\t\t\tAAAAAAAAAAAAAAAAAAAAAAAA /* CopyFiles */,\n"
                "\t\t\t\tBBBBBBBBBBBBBBBBBBBBBBBB /* Generate sealed Release build provenance */,",
                "\t\t\t\tBBBBBBBBBBBBBBBBBBBBBBBB /* Generate sealed Release build provenance */,\n"
                "\t\t\t\tAAAAAAAAAAAAAAAAAAAAAAAA /* CopyFiles */,",
            ),
            "not-last": generated.replace(
                "\t\t\t\tBBBBBBBBBBBBBBBBBBBBBBBB /* Generate sealed Release build provenance */,\n"
                "\t\t\t);",
                "\t\t\t\tBBBBBBBBBBBBBBBBBBBBBBBB /* Generate sealed Release build provenance */,\n"
                "\t\t\t\tEEEEEEEEEEEEEEEEEEEEEEEE /* Resources */,\n"
                "\t\t\t);",
            ),
            "no-output": generated.replace(
                "$(TARGET_BUILD_DIR)/$(UNLOCALIZED_RESOURCES_FOLDER_PATH)/MacScopeBuildProvenance.json",
                "$(TARGET_TEMP_DIR)/MacScopeBuildProvenance.json",
                1,
            ),
            "extra-surface-input": generated.replace(
                '\t\t\t\t"$(MACSCOPE_GHOSTTY_SURFACE_MODULE_MAP)",\n',
                '\t\t\t\t"$(MACSCOPE_GHOSTTY_SURFACE_MODULE_MAP)",\n'
                '\t\t\t\t"$(MACSCOPE_GHOSTTY_SURFACE_UNBOUND_INPUT)",\n',
                1,
            ),
            "misbound-surface-cli": generated.replace(
                '--ghostty-surface-staged-root \\"$MACSCOPE_GHOSTTY_SURFACE_STAGED_ROOT\\"',
                '--ghostty-surface-staged-root \\"$MACSCOPE_GHOSTTY_SURFACE_MANIFEST\\"',
                1,
            ),
            "third-surface-cli": generated.replace(
                '--ghostty-surface-staged-root \\"$MACSCOPE_GHOSTTY_SURFACE_STAGED_ROOT\\"',
                '--ghostty-surface-staged-root \\"$MACSCOPE_GHOSTTY_SURFACE_STAGED_ROOT\\" '
                '--ghostty-surface-unbound \\"$MACSCOPE_GHOSTTY_SURFACE_ARCHIVE\\"',
                1,
            ),
        }
        for name, mutated in mutations.items():
            with self.subTest(name=name):
                self.assertNotEqual(validator(mutated), [])

    def test_coretests_has_exact_final_fail_closed_provenance_copy_phase(self) -> None:
        module = load_guard_module()
        validator = getattr(
            module,
            "validate_coretests_provenance_copy_project_phase",
            None,
        )
        self.assertIsNotNone(validator)
        project_text = (REPOSITORY_ROOT / "MacScope" / "project.yml").read_text(
            encoding="utf-8"
        )

        self.assertEqual(validator(project_text), [])
        release_guard = (
            '          if [ "$CONFIGURATION" != "Release" ] && [ "$CONFIGURATION" != "Debug" ]; then\n'
            "            exit 1\n"
            "          fi\n"
        )
        for replacement in (
            release_guard.replace("exit 1", "exit 0"),
            '          if [ "$CONFIGURATION" != "Release" ]; then\n            exit 0\n          fi\n',
            '          if [ "$CONFIGURATION" = "Debug" ]; then\n            exit 0\n          fi\n' + release_guard,
        ):
            mutated = replacement.join(project_text.rsplit(release_guard, 1))
            with self.subTest(guard=replacement):
                self.assertNotEqual(mutated, project_text)
                self.assertNotEqual(validator(mutated), [])
        mutations = {
            "missing-supported-configuration-guard": "".join(
                project_text.rsplit(release_guard, 1)
            ),
            "wrong-source": project_text.replace(
                "$(BUILT_PRODUCTS_DIR)/MacScope.app/Contents/Resources/"
                "MacScopeBuildProvenance.json",
                "$(TARGET_BUILD_DIR)/Other.app/Contents/Resources/"
                "MacScopeBuildProvenance.json",
                1,
            ),
            "wrong-destination": "$(TARGET_TEMP_DIR)/MacScopeBuildProvenance.json".join(
                project_text.rsplit(
                    "$(TARGET_BUILD_DIR)/$(UNLOCALIZED_RESOURCES_FOLDER_PATH)/"
                    "MacScopeBuildProvenance.json",
                    1,
                )
            ),
            "not-mode-preserving": project_text.replace(
                '/bin/cp -p "$SOURCE" "$TEMPORARY"',
                '/bin/cp "$SOURCE" "$TEMPORARY"',
                1,
            ),
            "test-target-products-root": project_text.replace(
                "$(BUILT_PRODUCTS_DIR)/MacScope.app/Contents/Resources/",
                "$(TARGET_BUILD_DIR)/MacScope.app/Contents/Resources/",
                1,
            ),
        }
        for name, mutated in mutations.items():
            with self.subTest(name=name):
                self.assertNotEqual(validator(mutated), [])

    def test_generated_coretests_copy_is_dependency_bound_and_target_final(self) -> None:
        module = load_guard_module()
        validator = getattr(
            module,
            "validate_generated_coretests_provenance_copy_phase",
            None,
        )
        self.assertIsNotNone(validator)
        generated = r'''\
/* Begin PBXNativeTarget section */
		AAAAAAAAAAAAAAAAAAAAAAAA /* MacScopeApp */ = {
			isa = PBXNativeTarget;
			buildPhases = (
			);
			dependencies = (
			);
			name = MacScopeApp;
		};
		CCCCCCCCCCCCCCCCCCCCCCCC /* CoreTests */ = {
			isa = PBXNativeTarget;
			buildPhases = (
				DDDDDDDDDDDDDDDDDDDDDDDD /* Sources */,
				EEEEEEEEEEEEEEEEEEEEEEEE /* Resources */,
				BBBBBBBBBBBBBBBBBBBBBBBB /* Copy sealed provenance into CoreTests */,
			);
			dependencies = (
				FFFFFFFFFFFFFFFFFFFFFFFF /* PBXTargetDependency */,
			);
			name = CoreTests;
		};
/* End PBXNativeTarget section */
/* Begin PBXShellScriptBuildPhase section */
		BBBBBBBBBBBBBBBBBBBBBBBB /* Copy sealed provenance into CoreTests */ = {
			isa = PBXShellScriptBuildPhase;
			inputPaths = (
				"$(BUILT_PRODUCTS_DIR)/MacScope.app/Contents/Resources/MacScopeBuildProvenance.json",
			);
			name = "Copy sealed provenance into CoreTests";
			outputPaths = (
				"$(TARGET_BUILD_DIR)/$(UNLOCALIZED_RESOURCES_FOLDER_PATH)/MacScopeBuildProvenance.json",
			);
			shellScript = "set -eu\nif [ \"$CONFIGURATION\" != \"Release\" ] && [ \"$CONFIGURATION\" != \"Debug\" ]; then\nexit 1\nfi\nSOURCE=\"$BUILT_PRODUCTS_DIR/MacScope.app/Contents/Resources/MacScopeBuildProvenance.json\"\nDESTINATION=\"$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/MacScopeBuildProvenance.json\"\nif [ -L \"$SOURCE\" ]; then exit 1; fi\n/bin/cp -p \"$SOURCE\" \"$TEMPORARY\"\n/usr/bin/cmp -s \"$SOURCE\" \"$DESTINATION\"\n/usr/bin/stat -f '%Lp' \"$DESTINATION\"\n";
		};
/* End PBXShellScriptBuildPhase section */
/* Begin PBXTargetDependency section */
		FFFFFFFFFFFFFFFFFFFFFFFF /* PBXTargetDependency */ = {
			isa = PBXTargetDependency;
			target = AAAAAAAAAAAAAAAAAAAAAAAA /* MacScopeApp */;
		};
/* End PBXTargetDependency section */
'''

        self.assertEqual(validator(generated), [])
        guard = r'if [ \"$CONFIGURATION\" != \"Release\" ] && [ \"$CONFIGURATION\" != \"Debug\" ]; then\nexit 1\nfi\n'
        for replacement in (
            "",
            guard.replace("exit 1", "exit 0"),
            r'if [ \"$CONFIGURATION\" != \"Release\" ]; then\nexit 0\nfi\n',
            r'if [ \"$CONFIGURATION\" = \"Debug\" ]; then\nexit 0\nfi\n' + guard,
        ):
            mutated = generated.replace(guard, replacement, 1)
            with self.subTest(guard=replacement):
                self.assertNotEqual(mutated, generated)
                self.assertNotEqual(validator(mutated), [])
        mutations = {
            "not-last": generated.replace(
                "\t\t\t\tBBBBBBBBBBBBBBBBBBBBBBBB /* Copy sealed provenance into CoreTests */,\n"
                "\t\t\t);",
                "\t\t\t\tBBBBBBBBBBBBBBBBBBBBBBBB /* Copy sealed provenance into CoreTests */,\n"
                "\t\t\t\t999999999999999999999999 /* Resources */,\n"
                "\t\t\t);",
                1,
            ),
            "no-app-dependency": generated.replace(
                "\t\t\t\tFFFFFFFFFFFFFFFFFFFFFFFF /* PBXTargetDependency */,\n",
                "",
                1,
            ),
            "wrong-output": generated.replace(
                "$(TARGET_BUILD_DIR)/$(UNLOCALIZED_RESOURCES_FOLDER_PATH)/"
                "MacScopeBuildProvenance.json",
                "$(TARGET_TEMP_DIR)/MacScopeBuildProvenance.json",
                1,
            ),
            "test-target-products-root": generated.replace(
                "$(BUILT_PRODUCTS_DIR)/MacScope.app/Contents/Resources/",
                "$(TARGET_BUILD_DIR)/MacScope.app/Contents/Resources/",
                1,
            ),
            "always-out-of-date": generated.replace(
                "\t\t\tisa = PBXShellScriptBuildPhase;\n",
                "\t\t\tisa = PBXShellScriptBuildPhase;\n"
                "\t\t\talwaysOutOfDate = 1;\n",
                1,
            ),
        }
        for name, mutated in mutations.items():
            with self.subTest(name=name):
                self.assertNotEqual(validator(mutated), [])

    def test_coretests_copy_preserves_exact_bytes_and_mode_and_rejects_missing_or_symlink(self) -> None:
        project_lines = (REPOSITORY_ROOT / "MacScope" / "project.yml").read_text(
            encoding="utf-8"
        ).splitlines()
        phase_index = project_lines.index(
            "      - name: Copy sealed provenance into CoreTests"
        )
        script_index = project_lines.index("        script: |", phase_index)
        script_lines: list[str] = []
        for line in project_lines[script_index + 1 :]:
            if line.strip() and not line.startswith("          "):
                break
            script_lines.append(line[10:] if line else "")
        script = "\n".join(script_lines)

        with tempfile.TemporaryDirectory() as temporary_directory:
            products = Path(temporary_directory) / "Products"
            build = products / "MacScope.app/Contents/PlugIns"
            source = (
                products
                / "MacScope.app/Contents/Resources/MacScopeBuildProvenance.json"
            )
            source.parent.mkdir(parents=True)
            source.write_bytes(b'{"qualification_eligible":true}\n')
            source.chmod(0o640)
            environment = dict(os.environ)
            environment.update(
                {
                    "CONFIGURATION": "Release",
                    "BUILT_PRODUCTS_DIR": str(products),
                    "TARGET_BUILD_DIR": str(build),
                    "UNLOCALIZED_RESOURCES_FOLDER_PATH": (
                        "CoreTests.xctest/Contents/Resources"
                    ),
                }
            )

            result = subprocess.run(
                ["/bin/sh", "-c", script],
                check=False,
                capture_output=True,
                text=True,
                env=environment,
            )
            destination = (
                build
                / "CoreTests.xctest/Contents/Resources/MacScopeBuildProvenance.json"
            )
            self.assertEqual((result.returncode, result.stderr), (0, ""))
            self.assertEqual(destination.read_bytes(), source.read_bytes())
            self.assertEqual(
                stat.S_IMODE(destination.stat().st_mode),
                stat.S_IMODE(source.stat().st_mode),
            )

            source.unlink()
            missing = subprocess.run(
                ["/bin/sh", "-c", script],
                check=False,
                capture_output=True,
                text=True,
                env=environment,
            )
            self.assertNotEqual(missing.returncode, 0)

            real_source = build / "real-provenance.json"
            real_source.write_bytes(b"sealed\n")
            source.symlink_to(real_source)
            symlink = subprocess.run(
                ["/bin/sh", "-c", script],
                check=False,
                capture_output=True,
                text=True,
                env=environment,
            )
            self.assertNotEqual(symlink.returncode, 0)

    def test_source_runner_rejects_extra_source_and_missing_product(self) -> None:
        module = load_guard_module()
        text = (REPOSITORY_ROOT / "MacScope/project.yml").read_text(encoding="utf-8")
        altered = text.replace("      - path: SourceExecutionRunner/main.c",
            "      - path: SourceExecutionRunner/main.c\n      - path: App/MacScopeApp.swift")
        self.assertTrue(any("fixed main.c" in error for error in module.validate_app_target_guard(altered)))
        with tempfile.TemporaryDirectory() as directory:
            app = make_artifact_bundle(Path(directory))
            (app / "Contents/MacOS/SourceExecutionRunner").unlink()
            errors = module.validate_app_bundle(app, "Release", ArtifactFixtureRunner())
            self.assertTrue(any("SourceExecutionRunner" in error and "missing" in error for error in errors), errors)

    def test_app_and_workers_have_target_aware_always_run_guards(self) -> None:
        module = load_guard_module()
        project_text = (REPOSITORY_ROOT / "MacScope" / "project.yml").read_text(
            encoding="utf-8"
        )
        target_aware_command = (
            '/usr/bin/python3 "$SRCROOT/../Scripts/check_local_signing_policy.py" '
            '--build-environment --target "$TARGET_NAME"'
        )

        self.assertEqual(project_text.count(target_aware_command), 8)
        self.assertEqual(module.validate_app_target_guard(project_text), [])

        plugin_block_start = project_text.index("  PluginXPCService:")
        plugin_block_end = project_text.index(
            "  AnalysisWorkerXPCService:", plugin_block_start
        )
        plugin_block = project_text[plugin_block_start:plugin_block_end]
        plugin_mutation = project_text.replace(
            plugin_block,
            plugin_block.replace(target_aware_command, "# Plugin guard removed", 1),
        )
        errors = module.validate_app_target_guard(plugin_mutation)
        self.assertTrue(any("PluginXPCService" in error for error in errors), errors)

        worker_block_start = project_text.index("  AnalysisWorkerXPCService:")
        worker_block_end = project_text.index("  CoreTests:", worker_block_start)
        worker_block = project_text[worker_block_start:worker_block_end]
        mutated = project_text.replace(worker_block, worker_block.replace(
            target_aware_command,
            "# worker guard removed",
            1,
        ))
        errors = module.validate_app_target_guard(mutated)
        self.assertTrue(
            any("AnalysisWorkerXPCService" in error for error in errors),
            errors,
        )

        ai_worker_block_start = project_text.index("  AIAgentWorkerXPCService:")
        ai_worker_block_end = project_text.index("  CoreTests:", ai_worker_block_start)
        ai_worker_block = project_text[ai_worker_block_start:ai_worker_block_end]
        ai_worker_mutation = project_text.replace(
            ai_worker_block,
            ai_worker_block.replace(target_aware_command, "# AI worker guard removed", 1),
        )
        errors = module.validate_app_target_guard(ai_worker_mutation)
        self.assertTrue(
            any("AIAgentWorkerXPCService" in error for error in errors),
            errors,
        )

        shell_broker_block_start = project_text.index("  ShellBrokerXPCService:")
        shell_broker_block_end = project_text.index("  CoreTests:", shell_broker_block_start)
        shell_broker_block = project_text[shell_broker_block_start:shell_broker_block_end]
        shell_broker_mutation = project_text.replace(
            shell_broker_block,
            shell_broker_block.replace(
                target_aware_command,
                "# ShellBroker guard removed",
                1,
            ),
        )
        errors = module.validate_app_target_guard(shell_broker_mutation)
        self.assertTrue(
            any("ShellBrokerXPCService" in error for error in errors),
            errors,
        )

    def test_every_signed_production_target_is_registered_for_the_first_prebuild_guard(
        self,
    ) -> None:
        module = load_guard_module()
        project_text = (REPOSITORY_ROOT / "MacScope" / "project.yml").read_text(
            encoding="utf-8"
        )

        def signed_production_targets(text: str) -> set[str]:
            targets: set[str] = set()
            current_target: str | None = None
            in_targets = False
            for line in text.splitlines():
                if line == "targets:":
                    in_targets = True
                    continue
                if in_targets and line and not line.startswith(" "):
                    break
                if in_targets and line.startswith("  ") and not line.startswith("    "):
                    current_target = line.strip().removesuffix(":")
                    continue
                if current_target is not None and line.startswith("    type: "):
                    target_type = line.split(":", 1)[1].strip()
                    if target_type in {"application", "xpc-service", "tool"}:
                        targets.add(current_target)
            return targets

        configured = set(module.BUILD_PHASE_GUARDED_TARGETS)
        self.assertEqual(signed_production_targets(project_text), configured)

        mutation = project_text.replace(
            "  PluginXPCService:\n",
            "  UnguardedCanary:\n"
            "    type: application\n"
            "    platform: macOS\n"
            "    sources: []\n"
            "  PluginXPCService:\n",
            1,
        )
        self.assertIn("UnguardedCanary", signed_production_targets(mutation) - configured)

    def test_rejects_removed_moved_or_commented_app_target_guard(self) -> None:
        module = load_guard_module()
        project_text = (REPOSITORY_ROOT / "MacScope" / "project.yml").read_text(encoding="utf-8")
        command = (
            '          /usr/bin/python3 "$SRCROOT/../Scripts/'
            'check_local_signing_policy.py" --build-environment '
            '--target "$TARGET_NAME"'
        )
        mutations = {
            "removed": project_text.replace(f"{command}\n", "", 1),
            "moved": project_text.replace("    preBuildScripts:\n", "  preBuildScripts:\n", 1),
            "commented": project_text.replace(command, f"          # {command.strip()}", 1),
        }

        for name, mutated in mutations.items():
            with self.subTest(name=name):
                self.assertNotEqual(module.validate_app_target_guard(mutated), [])

    def test_accepts_only_explicit_isolated_ci_ad_hoc_build_environment(self) -> None:
        module = load_guard_module()
        environment = {
            "GITHUB_ACTIONS": "true",
            "CI": "true",
            "RUNNER_OS": "macOS",
            "RUNNER_ARCH": "ARM64",
            "MACSCOPE_ISOLATED_CI_ADHOC_SIGNING": "YES",
            "CONFIGURATION": "Debug",
            "AD_HOC_CODE_SIGNING_ALLOWED": "YES",
            "CODE_SIGNING_ALLOWED": "YES",
            "CODE_SIGNING_REQUIRED": "YES",
            "CODE_SIGN_STYLE": "Manual",
            "CODE_SIGN_IDENTITY": "-",
            "PROVISIONING_PROFILE": "",
            "PROVISIONING_PROFILE_SPECIFIER": "",
            # These are the effective values exported by Xcode after the
            # qualifier requests an empty team and hardened runtime with an
            # ad-hoc identity.
            "ENABLE_HARDENED_RUNTIME": "NO",
            "MACOSX_DEPLOYMENT_TARGET": "27.0",
            "PRODUCT_BUNDLE_IDENTIFIER": "org.macscope.app",
            "GENERATE_INFOPLIST_FILE": "NO",
            "INFOPLIST_FILE": "Resources/Info.plist",
            "CODE_SIGN_INJECT_BASE_ENTITLEMENTS": "YES",
        }

        self.assertEqual(module.validate_build_environment(environment), [])
        explicit_empty_team = dict(environment)
        explicit_empty_team["DEVELOPMENT_TEAM"] = ""
        self.assertEqual(
            module.validate_build_environment(explicit_empty_team),
            [],
        )
        for key, rejected in {
            "CI": "false",
            "RUNNER_OS": "Linux",
            "RUNNER_ARCH": "X64",
            "MACSCOPE_ISOLATED_CI_ADHOC_SIGNING": "NO",
            "AD_HOC_CODE_SIGNING_ALLOWED": "NO",
            "DEVELOPMENT_TEAM": "TEAM000000",
            "ENABLE_HARDENED_RUNTIME": "YES",
        }.items():
            with self.subTest(key=key):
                mutated = dict(environment)
                mutated[key] = rejected
                errors = module.validate_build_environment(mutated)
                self.assertTrue(any(key in error for error in errors), errors)

        github_actions_only = dict(environment)
        for key in (
            "CI",
            "RUNNER_OS",
            "RUNNER_ARCH",
            "MACSCOPE_ISOLATED_CI_ADHOC_SIGNING",
        ):
            github_actions_only.pop(key)
        self.assertNotEqual(
            module.validate_build_environment(github_actions_only),
            [],
        )

        local_certificate_environment = {
            key: value
            for key, value in environment.items()
            if key
            not in {
                "GITHUB_ACTIONS",
                "CI",
                "RUNNER_OS",
                "RUNNER_ARCH",
                "MACSCOPE_ISOLATED_CI_ADHOC_SIGNING",
            }
        }
        local_certificate_environment.update(
            {
                "AD_HOC_CODE_SIGNING_ALLOWED": "NO",
                "CODE_SIGN_STYLE": "Manual",
                "CODE_SIGN_IDENTITY": "Apple Development: MacScope Developer (CERT000000)",
                "DEVELOPMENT_TEAM": "TEAM000000",
                "ENABLE_HARDENED_RUNTIME": "YES",
                "CI": "true",
            }
        )
        self.assertEqual(
            module.validate_build_environment(local_certificate_environment),
            [],
        )

    def test_active_toolchain_accepts_macos_28_and_xcode_27_bundled_swift(self) -> None:
        module = load_guard_module()
        validator = getattr(module, "validate_active_toolchain", None)
        self.assertIsNotNone(validator)
        environment = {
            "DEVELOPER_DIR": "/Applications/Xcode-beta.app/Contents/Developer"
        }
        runner = ToolchainFixtureRunner()

        self.assertEqual(validator(environment, runner), [])

        runner.override(
            ("/usr/bin/xcrun", "swift", "--version"),
            stdout="Apple Swift version 6.5 (swiftlang-test clang-test)\n",
        )
        self.assertEqual(validator(environment, runner), [])

    def test_active_toolchain_rejects_wrong_xcode_sdk_arch_and_old_host(self) -> None:
        module = load_guard_module()
        validator = getattr(module, "validate_active_toolchain", None)
        self.assertIsNotNone(validator)
        environment = {
            "DEVELOPER_DIR": "/Applications/Xcode-beta.app/Contents/Developer"
        }
        mutations = {
            "arm64": (("/usr/bin/uname", "-m"), "x86_64\n"),
            "macOS 27.0 or newer": (
                ("/usr/bin/sw_vers", "-productVersion"),
                "26.6\n",
            ),
            "Xcode 27": (
                ("/usr/bin/xcrun", "xcodebuild", "-version"),
                "Xcode 28.0\nBuild version 28A1\n",
            ),
            "macOS SDK 27": (
                ("/usr/bin/xcrun", "--sdk", "macosx", "--show-sdk-version"),
                "28.0\n",
            ),
        }
        for expected_error, (command, stdout) in mutations.items():
            with self.subTest(expected_error=expected_error):
                runner = ToolchainFixtureRunner()
                runner.override(command, stdout=stdout)
                errors = validator(environment, runner)
                self.assertTrue(
                    any(expected_error in error for error in errors),
                    errors,
                )

    def test_build_environment_cli_reuses_bootstrap_toolchain_guard(self) -> None:
        guard_source = GUARD.read_text(encoding="utf-8")
        build_phase_branch = guard_source.split(
            "    if arguments.build_environment:\n", 1
        )[1].split("    if arguments.source_app_bundle", 1)[0]

        self.assertIn("validate_build_environment(dict(os.environ)", build_phase_branch)
        self.assertNotIn("validate_active_toolchain", build_phase_branch)
        self.assertIn("return 0", build_phase_branch)
        self.assertIn('parser.add_argument("--active-toolchain"', guard_source)

    def test_shell_toolchain_guard_accepts_newer_hosts_and_xcode_27_bundled_swift(self) -> None:
        script = (REPOSITORY_ROOT / "Scripts" / "xcode27_env.sh").read_text(
            encoding="utf-8"
        )

        self.assertIn('(( macos_major >= 27 ))', script)
        self.assertNotIn('[[ "${macos_major}" == "27" ]]', script)
        self.assertIn('/usr/bin/xcrun swift --version', script)
        self.assertNotRegex(script, r'expected Swift [0-9]')

    def test_shell_toolchain_guard_is_sourceable_from_bash_and_zsh(self) -> None:
        script = REPOSITORY_ROOT / "Scripts" / "xcode27_env.sh"
        environment = dict(os.environ)
        environment.setdefault(
            "DEVELOPER_DIR", "/Applications/Xcode.app/Contents/Developer"
        )

        for shell in ("/bin/bash", "/bin/zsh"):
            with self.subTest(shell=shell):
                completed = subprocess.run(
                    [shell, "-c", f"source {shlex.quote(str(script))}"],
                    capture_output=True,
                    text=True,
                    env=environment,
                    check=False,
                )
                self.assertEqual(
                    completed.returncode,
                    0,
                    completed.stdout + completed.stderr,
                )

    def test_accepts_certificate_backed_app_and_embedded_worker_artifacts(self) -> None:
        module = load_guard_module()
        with tempfile.TemporaryDirectory() as temporary_directory:
            app = make_artifact_bundle(Path(temporary_directory))
            runner = ArtifactFixtureRunner()

            errors = module.validate_app_bundle(app, "Release", runner)

        self.assertEqual(errors, [])
        verified_paths = {
            Path(call[-1]).name
            for call in runner.calls
            if "--verify" in call
            and "--deep" in call
            and "--strict" in call
        }
        self.assertEqual(
            verified_paths,
            {
                "MacScope.app",
                "AnalysisWorkerXPCService.xpc",
                "AIAgentWorkerXPCService.xpc",
                "NativeDecompilerXPCService.xpc",
                "ShellBrokerXPCService.xpc",
                "ShellBrokerLaunchAgent",
                "libghostty-vt.dylib",
                "SourceExecutionRunner",
            },
        )
        deployment_checked_paths = {
            Path(call[-1]).name
            for call in runner.calls
            if call[:3] == ("/usr/bin/xcrun", "vtool", "-show-build")
        }
        self.assertEqual(
            deployment_checked_paths,
            {
                "MacScope",
                "AnalysisWorkerXPCService",
                "AIAgentWorkerXPCService",
                "NativeDecompilerXPCService",
                "ShellBrokerXPCService",
                "ShellBrokerLaunchAgent",
                "libghostty-vt.dylib",
                "SourceExecutionRunner",
            },
        )

    def test_release_provenance_contract_requires_ghostty_surface_cli_seam(self) -> None:
        module = load_guard_module()

        self.assertEqual(
            module.RELEASE_PROVENANCE_GHOSTTY_SURFACE_INPUTS,
            (
                "$(MACSCOPE_GHOSTTY_SURFACE_MANIFEST)",
                "$(MACSCOPE_GHOSTTY_SURFACE_STAGED_DESCRIPTOR)",
                "$(MACSCOPE_GHOSTTY_SURFACE_ARCHIVE)",
                "$(MACSCOPE_GHOSTTY_SURFACE_HEADER)",
                "$(MACSCOPE_GHOSTTY_SURFACE_MODULE_MAP)",
            ),
        )
        self.assertIn(
            '            --ghostty-surface-manifest '
            '"$MACSCOPE_GHOSTTY_SURFACE_MANIFEST" \\',
            module.RELEASE_PROVENANCE_COMMAND_LINES,
        )
        self.assertIn(
            '            --ghostty-surface-staged-root '
            '"$MACSCOPE_GHOSTTY_SURFACE_STAGED_ROOT" \\',
            module.RELEASE_PROVENANCE_COMMAND_LINES,
        )

        project_text = (REPOSITORY_ROOT / "MacScope" / "project.yml").read_text(
            encoding="utf-8"
        )
        native_tail = (
            '          - "$(TARGET_BUILD_DIR)/$(CONTENTS_FOLDER_PATH)/XPCServices/'
            'NativeDecompilerXPCService.xpc/Contents/_CodeSignature/CodeResources"\n'
        )
        analysis_input = (
            '          - "$(TARGET_BUILD_DIR)/$(CONTENTS_FOLDER_PATH)/XPCServices/'
            'AnalysisWorkerXPCService.xpc/Contents/MacOS/AnalysisWorkerXPCService"\n'
        )
        concrete_inputs = "".join(
            f'          - "{path}"\n'
            for path in module.RELEASE_PROVENANCE_GHOSTTY_SURFACE_INPUTS
        )
        self.assertEqual(
            project_text.count(native_tail + concrete_inputs + analysis_input),
            1,
        )
        source_root_command = (
            '            --ghostty-source-dir "$SRCROOT/../ThirdParty/GhosttyVT/Source" \\\n'
        )
        sleigh_command = (
            '            --sleigh-materialization-root '
            '"$MACSCOPE_SLEIGH_MATERIALIZATION_ROOT" \\\n'
        )
        surface_commands = "\n".join(
            line
            for line in module.RELEASE_PROVENANCE_COMMAND_LINES
            if "--ghostty-surface-" in line
        ) + "\n"
        self.assertEqual(
            project_text.count(
                source_root_command + surface_commands + sleigh_command
            ),
            1,
        )
        wired_project = project_text
        self.assertEqual(
            module.validate_release_provenance_project_phase(wired_project),
            [],
        )
        release_phase_offset = wired_project.index(
            "      - name: Generate sealed Release build provenance\n"
        )
        for path in module.RELEASE_PROVENANCE_GHOSTTY_SURFACE_INPUTS:
            with self.subTest(missing_input=path):
                input_line = f'          - "{path}"\n'
                input_offset = wired_project.index(input_line, release_phase_offset)
                mutated = (
                    wired_project[:input_offset]
                    + wired_project[input_offset + len(input_line) :]
                )
                self.assertTrue(
                    module.validate_release_provenance_project_phase(mutated)
                )
        surface_cli_lines = [
            line
            for line in module.RELEASE_PROVENANCE_COMMAND_LINES
            if "--ghostty-surface-" in line
        ]
        self.assertEqual(len(surface_cli_lines), 2)
        for line in surface_cli_lines:
            with self.subTest(missing_cli=line):
                mutated = wired_project.replace(f"{line}\n", "", 1)
                self.assertTrue(
                    module.validate_release_provenance_project_phase(mutated)
                )
        staged_root_cli = next(
            line for line in surface_cli_lines if "--ghostty-surface-staged-root" in line
        )
        misbound = wired_project.replace(
            staged_root_cli,
            staged_root_cli.replace(
                "$MACSCOPE_GHOSTTY_SURFACE_STAGED_ROOT",
                "$MACSCOPE_GHOSTTY_SURFACE_MANIFEST",
            ),
            1,
        )
        self.assertTrue(module.validate_release_provenance_project_phase(misbound))
        module_map_line = '          - "$(MACSCOPE_GHOSTTY_SURFACE_MODULE_MAP)"\n'
        module_map_offset = wired_project.index(
            module_map_line,
            release_phase_offset,
        )
        unexpected_input = (
            wired_project[: module_map_offset + len(module_map_line)]
            + '          - "$(MACSCOPE_GHOSTTY_SURFACE_UNBOUND_INPUT)"\n'
            + wired_project[module_map_offset + len(module_map_line) :]
        )
        self.assertTrue(
            module.validate_release_provenance_project_phase(unexpected_input)
        )

    def test_release_candidate_rejects_missing_stale_or_unbound_provenance(self) -> None:
        module = load_guard_module()
        commit = "1" * 40
        tree = "2" * 40
        with tempfile.TemporaryDirectory() as temporary_directory:
            app = make_artifact_bundle(Path(temporary_directory))
            payload, errors = module.validate_release_provenance(
                app,
                expected_source_commit=commit,
                expected_source_tree=tree,
            )
            self.assertIsNotNone(payload)
            self.assertEqual(errors, [])

        mutations = (
            ({"configuration": "Debug"}, "configuration"),
            ({"qualification_eligible": False}, "qualification_eligible"),
            ({"repository_clean": False}, "repository_clean"),
            (
                {"ghostty_surface_source_tree": "0" * 40},
                "ghostty_surface_source_tree",
            ),
            (
                {
                    "ghostty_surface_staged_descriptor_relative_path": (
                        "STALE_GHOSTTY_SURFACE.json"
                    )
                },
                "staged_descriptor_relative_path",
            ),
            ({"git_head_commit": "f" * 40}, "admitted candidate commit"),
        )
        for changes, expected_error in mutations:
            with self.subTest(mutation=expected_error):
                with tempfile.TemporaryDirectory() as temporary_directory:
                    app = make_artifact_bundle(Path(temporary_directory))
                    update_release_provenance(app, **changes)
                    _payload, errors = module.validate_release_provenance(
                        app,
                        expected_source_commit=commit,
                        expected_source_tree=tree,
                    )
                self.assertTrue(
                    any(expected_error in error for error in errors),
                    errors,
                )

        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            app = make_artifact_bundle(root)
            provenance = app / "Contents/Resources/MacScopeBuildProvenance.json"
            provenance.unlink()
            _payload, missing_errors = module.validate_release_provenance(app)
            self.assertTrue(any("missing" in error for error in missing_errors))

            target = root / "foreign-provenance.json"
            target.write_bytes(b"{}\n")
            provenance.symlink_to(target)
            _payload, symlink_errors = module.validate_release_provenance(app)
            self.assertTrue(
                any("ordinary singly linked" in error for error in symlink_errors),
                symlink_errors,
            )

    def test_release_provenance_binds_candidate_executables_and_code_resources(self) -> None:
        module = load_guard_module()
        commit = "1" * 40
        tree = "2" * 40
        mutations = (
            (
                Path(
                    "Contents/XPCServices/AnalysisWorkerXPCService.xpc/Contents/"
                    "MacOS/AnalysisWorkerXPCService"
                ),
                "machokit_analysis_worker_executable_sha256",
            ),
            (
                Path(
                    "Contents/XPCServices/NativeDecompilerXPCService.xpc/Contents/"
                    "MacOS/NativeDecompilerXPCService"
                ),
                "native_decompiler_embedded_service_executable_sha256",
            ),
            (
                Path(
                    "Contents/XPCServices/NativeDecompilerXPCService.xpc/Contents/"
                    "_CodeSignature/CodeResources"
                ),
                "native_decompiler_embedded_service_code_resources_sha256",
            ),
        )
        for relative, binding in mutations:
            with self.subTest(binding=binding):
                with tempfile.TemporaryDirectory() as temporary_directory:
                    app = make_artifact_bundle(Path(temporary_directory))
                    (app / relative).write_bytes(b"mixed-candidate-mutation\n")
                    _payload, errors = module.validate_release_provenance(
                        app,
                        expected_source_commit=commit,
                        expected_source_tree=tree,
                    )
                self.assertTrue(any(binding in error for error in errors), errors)

    def test_release_candidate_requires_exact_product_inventory_and_safe_paths(self) -> None:
        module = load_guard_module()
        with tempfile.TemporaryDirectory() as temporary_directory:
            app = make_artifact_bundle(Path(temporary_directory))
            unexpected = app / "Contents/XPCServices/UnexpectedWorker.xpc"
            unexpected.mkdir()
            errors = module.validate_app_bundle(app, "Release", ArtifactFixtureRunner())
            self.assertTrue(
                any("exactly the four approved XPC services" in error for error in errors),
                errors,
            )

        with tempfile.TemporaryDirectory() as temporary_directory:
            app = make_artifact_bundle(Path(temporary_directory))
            (app / "Contents/Frameworks/Unexpected.framework").touch()
            errors = module.validate_app_bundle(app, "Release", ArtifactFixtureRunner())
            self.assertTrue(
                any("Contents/Frameworks must contain exactly" in error for error in errors),
                errors,
            )

        for relative, label in (
            (
                "Contents/Frameworks/libghostty-vt.dylib",
                "libghostty-vt.dylib",
            ),
            (
                "Contents/MacOS/ShellBrokerLaunchAgent",
                "ShellBrokerLaunchAgent",
            ),
        ):
            with self.subTest(hardlinked=label):
                with tempfile.TemporaryDirectory() as temporary_directory:
                    root = Path(temporary_directory)
                    app = make_artifact_bundle(root)
                    artifact = app / relative
                    os.link(artifact, root / f"{label}.alias")
                    errors = module.validate_app_bundle(
                        app,
                        "Release",
                        ArtifactFixtureRunner(),
                    )
                self.assertTrue(
                    any(label in error and "singly linked" in error for error in errors),
                    errors,
                )

        with tempfile.TemporaryDirectory() as temporary_directory:
            app = make_artifact_bundle(Path(temporary_directory))
            info_plist = app / "Contents/Info.plist"
            with info_plist.open("rb") as stream:
                metadata = plistlib.load(stream)
            metadata["CFBundleExecutable"] = "ShellBrokerLaunchAgent"
            with info_plist.open("wb") as stream:
                plistlib.dump(metadata, stream)
            errors = module.validate_app_bundle(app, "Release", ArtifactFixtureRunner())
            self.assertTrue(
                any("CFBundleExecutable must be 'MacScope'" in error for error in errors),
                errors,
            )

        with tempfile.TemporaryDirectory() as temporary_directory:
            app = make_artifact_bundle(Path(temporary_directory))
            (app / "Contents/MacOS/OtherLaunchAgent").touch()
            errors = module.validate_app_bundle(app, "Release", ArtifactFixtureRunner())
            self.assertTrue(
                any("Contents/MacOS must contain exactly" in error for error in errors),
                errors,
            )

        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            app = make_artifact_bundle(root)
            worker = app / "Contents/XPCServices/AnalysisWorkerXPCService.xpc"
            moved = root / "AnalysisWorkerXPCService.xpc"
            worker.rename(moved)
            worker.symlink_to(moved, target_is_directory=True)
            errors = module.validate_app_bundle(app, "Release", ArtifactFixtureRunner())
            self.assertTrue(
                any("symlink" in error and "AnalysisWorker" in error for error in errors),
                errors,
            )

        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            app = make_artifact_bundle(root)
            launch_agent = app / "Contents/MacOS/ShellBrokerLaunchAgent"
            target = root / "foreign-launch-agent"
            target.write_bytes(b"foreign\n")
            launch_agent.unlink()
            launch_agent.symlink_to(target)
            errors = module.validate_app_bundle(app, "Release", ArtifactFixtureRunner())
            self.assertTrue(
                any("ShellBrokerLaunchAgent" in error and "non-symlink" in error for error in errors),
                errors,
            )

        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            app = make_artifact_bundle(root)
            code_resources = app / "Contents/_CodeSignature/CodeResources"
            target = root / "foreign-code-resources"
            target.write_bytes(code_resources.read_bytes())
            code_resources.unlink()
            code_resources.symlink_to(target)
            errors = module.validate_app_bundle(app, "Release", ArtifactFixtureRunner())
            self.assertTrue(
                any("MacScope.app CodeResources" in error for error in errors),
                errors,
            )

    def test_every_release_product_rejects_adhoc_and_distribution_signers(self) -> None:
        module = load_guard_module()
        products = {
            "app": ("MacScope.app", "org.macscope.app"),
            "worker": (
                "AnalysisWorkerXPCService.xpc",
                "org.macscope.app.AnalysisWorker",
            ),
            "ai_worker": (
                "AIAgentWorkerXPCService.xpc",
                "org.macscope.app.AIAgentWorker",
            ),
            "native_decompiler": (
                "NativeDecompilerXPCService.xpc",
                "org.macscope.app.NativeDecompiler",
            ),
            "shell_broker": (
                "ShellBrokerXPCService.xpc",
                "org.macscope.app.ShellBroker",
            ),
            "source_runner": ("SourceExecutionRunner", "org.macscope.app.SourceExecutionRunner"),
            "shell_launch_agent": (
                "ShellBrokerLaunchAgent",
                "org.macscope.app.ShellBrokerLaunchAgent",
            ),
            "ghostty_vt": (
                "libghostty-vt.dylib",
                "org.macscope.app.GhosttyVT",
            ),
        }
        forbidden_signers = (
            "adhoc",
            "Developer ID Application: MacScope Developer (CERT000000)",
            "Apple Distribution: MacScope Developer (CERT000000)",
        )
        for target, (label, identifier) in products.items():
            for signer in forbidden_signers:
                with self.subTest(product=label, signer=signer):
                    with tempfile.TemporaryDirectory() as temporary_directory:
                        app = make_artifact_bundle(Path(temporary_directory))
                        runner = ArtifactFixtureRunner()
                        runner.override(
                            "details",
                            target,
                            stderr=signed_details_fixture(identifier, signer=signer),
                        )
                        runner.override(
                            "requirements",
                            target,
                            stderr=designated_requirement_fixture(
                                identifier,
                                signer=signer,
                            ),
                        )
                        errors = module.validate_app_bundle(app, "Release", runner)
                    self.assertTrue(
                        any(
                            label in error and "Apple Development" in error
                            for error in errors
                        ),
                        errors,
                    )

    def test_release_requires_exact_launch_agent_signing_contract(self) -> None:
        module = load_guard_module()
        identifier = "org.macscope.app.ShellBrokerLaunchAgent"
        mutations = {
            "leaf signer": (
                "details",
                signed_details_fixture(
                    identifier,
                    signer="Apple Development: Different Developer (OTHERID123)",
                ),
                "leaf Authority",
            ),
            "designated requirement": (
                "requirements",
                designated_requirement_fixture(identifier + ".drifted"),
                "designated requirement",
            ),
            "entitlements": (
                "entitlements",
                plistlib.dumps(
                    {"com.apple.security.get-task-allow": True}
                ).decode("utf-8"),
                "entitlements must exactly match",
            ),
        }
        for mutation, (action, output, expected_error) in mutations.items():
            with self.subTest(mutation=mutation):
                with tempfile.TemporaryDirectory() as temporary_directory:
                    app = make_artifact_bundle(Path(temporary_directory))
                    runner = ArtifactFixtureRunner()
                    if action in {"details", "requirements"}:
                        runner.override(
                            action,
                            "shell_launch_agent",
                            stderr=output,
                        )
                    else:
                        runner.override(
                            action,
                            "shell_launch_agent",
                            stdout=output,
                        )
                    errors = module.validate_app_bundle(app, "Release", runner)
                self.assertTrue(
                    any(
                        "ShellBrokerLaunchAgent" in error
                        and expected_error in error
                        for error in errors
                    ),
                    errors,
                )

        with tempfile.TemporaryDirectory() as temporary_directory:
            app = make_artifact_bundle(Path(temporary_directory))
            (app / "Contents/MacOS/ShellBrokerLaunchAgent").unlink()
            errors = module.validate_app_bundle(
                app,
                "Release",
                ArtifactFixtureRunner(),
            )
        self.assertTrue(
            any(
                "ShellBrokerLaunchAgent" in error and "missing" in error
                for error in errors
            ),
            errors,
        )

    def test_release_requires_exact_launch_agent_development_entitlements(self) -> None:
        module = load_guard_module()
        expected = RELEASE_SHELL_BROKER_LAUNCH_AGENT_ENTITLEMENTS_FIXTURE
        mutations = {
            "empty legacy fixture": {},
            "missing application identifier": {
                "com.apple.security.get-task-allow": True,
            },
            "missing get-task-allow": {
                "com.apple.application-identifier": expected["com.apple.application-identifier"],
            },
            "wrong application identifier": {
                **expected,
                "com.apple.application-identifier": "TEAM000000.org.macscope.app.OtherLaunchAgent",
            },
            "wrong team": {
                **expected,
                "com.apple.application-identifier": "OTHERTEAM1.org.macscope.app.ShellBrokerLaunchAgent",
            },
            "disabled get-task-allow": {
                **expected, "com.apple.security.get-task-allow": False,
            },
            "extra entitlement": {
                **expected, "com.apple.security.cs.disable-library-validation": True,
            },
            "test-host exceptions in ordinary Release": SHELL_BROKER_LAUNCH_AGENT_ENTITLEMENTS_FIXTURE,
        }
        with tempfile.TemporaryDirectory() as temporary_directory:
            app = make_artifact_bundle(Path(temporary_directory))
            self.assertEqual(
                module.validate_app_bundle(app, "Release", ArtifactFixtureRunner()), []
            )
            for mutation, profile in mutations.items():
                with self.subTest(mutation=mutation):
                    runner = ArtifactFixtureRunner()
                    runner.override(
                        "entitlements", "shell_launch_agent",
                        stdout=plistlib.dumps(profile).decode("utf-8"),
                    )
                    errors = module.validate_app_bundle(app, "Release", runner)
                    self.assertTrue(
                        any(
                            "ShellBrokerLaunchAgent entitlements must exactly match" in error
                            for error in errors
                        ), errors,
                    )

    def test_release_requires_exact_ghostty_vt_signing_contract(self) -> None:
        module = load_guard_module()
        identifier = "org.macscope.app.GhosttyVT"
        mutations = {
            "signed identifier": (
                "details",
                signed_details_fixture(identifier + ".drifted"),
                "signed Identifier",
            ),
            "hardened runtime": (
                "details",
                signed_details_fixture(identifier, runtime=False),
                "hardened runtime",
            ),
            "designated requirement": (
                "requirements",
                designated_requirement_fixture(identifier + ".drifted"),
                "designated requirement",
            ),
            "entitlements": (
                "entitlements",
                plistlib.dumps(
                    {"com.apple.security.get-task-allow": True}
                ).decode("utf-8"),
                "empty dylib entitlement profile",
            ),
        }
        for mutation, (action, output, expected_error) in mutations.items():
            with self.subTest(mutation=mutation):
                with tempfile.TemporaryDirectory() as temporary_directory:
                    app = make_artifact_bundle(Path(temporary_directory))
                    runner = ArtifactFixtureRunner()
                    if action == "entitlements":
                        runner.override(action, "ghostty_vt", stdout=output)
                    else:
                        runner.override(action, "ghostty_vt", stderr=output)
                    errors = module.validate_app_bundle(app, "Release", runner)
                self.assertTrue(
                    any(
                        "libghostty-vt.dylib" in error
                        and expected_error in error
                        for error in errors
                    ),
                    errors,
                )

    def test_release_rejects_ghostty_vt_mutation_during_signing_validation(
        self,
    ) -> None:
        module = load_guard_module()
        with tempfile.TemporaryDirectory() as temporary_directory:
            app = make_artifact_bundle(Path(temporary_directory))
            ghostty_vt = app / "Contents/Frameworks/libghostty-vt.dylib"
            base_runner = ArtifactFixtureRunner()
            mutated = False

            def mutating_runner(
                command: list[str],
            ) -> subprocess.CompletedProcess[str]:
                nonlocal mutated
                result = base_runner(command)
                if (
                    not mutated
                    and command[:2] == ["/usr/bin/codesign", "-dvvv"]
                    and command[-1].endswith("/libghostty-vt.dylib")
                ):
                    ghostty_vt.write_bytes(b"substituted-during-validation\n")
                    mutated = True
                return result

            errors = module.validate_app_bundle(
                app,
                "Release",
                mutating_runner,
            )

        self.assertTrue(
            any(
                "libghostty-vt.dylib executable changed during validation" in error
                for error in errors
            ),
            errors,
        )

    def test_release_rejects_nonembedded_plugin_from_exact_xpc_inventory(self) -> None:
        module = load_guard_module()
        with tempfile.TemporaryDirectory() as temporary_directory:
            app = make_artifact_bundle(Path(temporary_directory))
            add_plugin_artifact(app)
            runner = ArtifactFixtureRunner()

            errors = module.validate_app_bundle(app, "Release", runner)

        self.assertTrue(
            any("exactly the four approved XPC services" in error for error in errors),
            errors,
        )
        verified_paths = {
            Path(call[-1]).name
            for call in runner.calls
            if "--verify" in call and "--deep" in call and "--strict" in call
        }
        self.assertEqual(
            verified_paths,
            {
                "MacScope.app",
                "AnalysisWorkerXPCService.xpc",
                "AIAgentWorkerXPCService.xpc",
                "NativeDecompilerXPCService.xpc",
                "ShellBrokerXPCService.xpc",
                "ShellBrokerLaunchAgent",
                "libghostty-vt.dylib",
                "SourceExecutionRunner",
            },
        )

    def test_install_equality_accepts_identical_app_and_worker_executables(self) -> None:
        module = load_guard_module()
        validator = getattr(module, "validate_installed_app_matches_source", None)
        self.assertIsNotNone(validator)
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            source = make_artifact_bundle(root / "source")
            installed = make_artifact_bundle(root / "installed")
            for app in (source, installed):
                (app / "Contents" / "MacOS" / "MacScope").write_bytes(b"main-v1")
                (
                    app
                    / "Contents"
                    / "XPCServices"
                    / "AnalysisWorkerXPCService.xpc"
                    / "Contents"
                    / "MacOS"
                    / "AnalysisWorkerXPCService"
                ).write_bytes(b"worker-v1")
                (
                    app
                    / "Contents"
                    / "XPCServices"
                    / "AIAgentWorkerXPCService.xpc"
                    / "Contents"
                    / "MacOS"
                    / "AIAgentWorkerXPCService"
                ).write_bytes(b"ai-worker-v1")

            errors = validator(source, installed)

            authority, collected_errors = module.collect_installed_source_equality(
                source, installed
            )

        self.assertEqual(errors, [])
        self.assertEqual(collected_errors, [])
        self.assertIsNotNone(authority)
        self.assertEqual(
            set(authority),
            {
                "release_bundle_sha256",
                "release_closed_tree_sha256",
                "release_executable_sha256",
                "installed_bundle_sha256",
                "installed_closed_tree_sha256",
                "installed_executable_sha256",
            },
        )
        for identity in ("bundle_sha256", "closed_tree_sha256", "executable_sha256"):
            self.assertEqual(
                authority[f"release_{identity}"],
                authority[f"installed_{identity}"],
            )
            self.assertRegex(authority[f"release_{identity}"], r"^[0-9a-f]{64}$")

    def test_install_equality_rejects_parent_alias_to_same_bundle(self) -> None:
        module = load_guard_module()
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            source_parent = root / "source"
            source = make_artifact_bundle(source_parent)
            alias_parent = root / "source-alias"
            alias_parent.symlink_to(source_parent, target_is_directory=True)
            installed_alias = alias_parent / "MacScope.app"

            authority, errors = module.collect_installed_source_equality(
                source,
                installed_alias,
            )

        self.assertIsNone(authority)
        self.assertTrue(any("physically distinct" in error for error in errors), errors)

    def test_install_equality_accepts_only_ctime_root_xattr_churn(self) -> None:
        module = load_guard_module()
        for changed_side in ("source", "installed"):
            with self.subTest(changed_side=changed_side), tempfile.TemporaryDirectory(
                dir=os.environ.get("MACSCOPE_TEST_TEMP_ROOT")
            ) as temporary_directory:
                root = Path(temporary_directory)
                source = make_artifact_bundle(root / "source")
                installed = make_artifact_bundle(root / "installed")
                changed_root = source if changed_side == "source" else installed
                before = changed_root.stat()
                original_digests = module.bundle_tree_digests

                def inspect_with_root_metadata_churn(app):
                    if app == changed_root:
                        set_fixture_xattr(app, b"root metadata only")
                        after = app.stat()
                        self.assertEqual(module.stable_artifact_fields(before)[:-1],
                                         module.stable_artifact_fields(after)[:-1])
                        self.assertNotEqual(before.st_ctime_ns, after.st_ctime_ns)
                    return original_digests(app)

                with patch.object(module, "bundle_tree_digests", inspect_with_root_metadata_churn):
                    authority, errors = module.collect_installed_source_equality(source, installed)
                self.assertEqual(errors, [])
                self.assertIsNotNone(authority)
                for identity in ("bundle_sha256", "closed_tree_sha256", "executable_sha256"):
                    self.assertEqual(authority["release_" + identity], authority["installed_" + identity])

    def test_install_equality_rejects_root_replacement_mode_and_content_during_collection(self) -> None:
        module = load_guard_module()
        for mutation in ("replacement", "mode", "content", "mtime"):
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory(
                dir=os.environ.get("MACSCOPE_TEST_TEMP_ROOT")
            ) as temporary_directory:
                root = Path(temporary_directory)
                source = make_artifact_bundle(root / "source")
                installed = make_artifact_bundle(root / "installed")
                original_digests = module.bundle_tree_digests

                def inspect_with_physical_mutation(app):
                    if app == installed:
                        if mutation == "replacement":
                            parked = root / "original-installed.app"
                            app.rename(parked)
                            shutil.copytree(parked, app)
                        elif mutation == "mode":
                            app.chmod(stat.S_IMODE(app.stat().st_mode) ^ stat.S_IXOTH)
                        elif mutation == "mtime":
                            observed = app.stat()
                            os.utime(app, ns=(observed.st_atime_ns, observed.st_mtime_ns + 1_000_000_000))
                        else:
                            (app / "Contents/_CodeSignature/CodeResources").write_bytes(b"changed signature resource")
                    return original_digests(app)

                with patch.object(module, "bundle_tree_digests", inspect_with_physical_mutation):
                    _, errors = module.collect_installed_source_equality(source, installed)
                expected = "bundle SHA-256" if mutation == "content" else "root changed"
                self.assertTrue(any(expected in error for error in errors), errors)
                if mutation != "content":
                    changed_field = {"replacement": "inode", "mode": "mode", "mtime": "mtime_ns"}[mutation]
                    diagnostic = next(error for error in errors if "root changed" in error)
                    self.assertIn(changed_field, diagnostic.split("changed fields: ")[1])

    def test_regular_artifact_hash_still_rejects_ctime_only_xattr_churn(self) -> None:
        module = load_guard_module()
        with tempfile.TemporaryDirectory(dir=os.environ.get("MACSCOPE_TEST_TEMP_ROOT")) as temporary_directory:
            path = Path(temporary_directory) / "artifact"
            path.write_bytes(b"unchanged regular file bytes")
            before = path.stat()
            original_read = os.read
            mutated = False

            def read_with_metadata_churn(descriptor, count):
                nonlocal mutated
                result = original_read(descriptor, count)
                if result and not mutated:
                    mutated = True
                    set_fixture_xattr(path, b"file metadata only")
                    after = path.stat()
                    self.assertEqual(module.stable_artifact_fields(before)[:-1],
                                     module.stable_artifact_fields(after)[:-1])
                    self.assertNotEqual(before.st_ctime_ns, after.st_ctime_ns)
                return result

            with patch.object(module.os, "read", read_with_metadata_churn):
                with self.assertRaisesRegex(ValueError, "changed while hashed"):
                    module.sha256_stable_artifact_file(path, "regular artifact")

    def test_install_equality_rejects_main_or_worker_executable_drift(self) -> None:
        module = load_guard_module()
        validator = getattr(module, "validate_installed_app_matches_source", None)
        self.assertIsNotNone(validator)
        for drifted_product, relative_path in (
            ("MacScope.app executable", Path("Contents/MacOS/MacScope")),
            ("SourceExecutionRunner", Path("Contents/MacOS/SourceExecutionRunner")),
            (
                "AnalysisWorkerXPCService.xpc executable",
                Path(
                    "Contents/XPCServices/AnalysisWorkerXPCService.xpc/Contents/"
                    "MacOS/AnalysisWorkerXPCService"
                ),
            ),
            (
                "AIAgentWorkerXPCService.xpc executable",
                Path(
                    "Contents/XPCServices/AIAgentWorkerXPCService.xpc/Contents/"
                    "MacOS/AIAgentWorkerXPCService"
                ),
            ),
        ):
            with self.subTest(drifted_product=drifted_product):
                with tempfile.TemporaryDirectory() as temporary_directory:
                    root = Path(temporary_directory)
                    source = make_artifact_bundle(root / "source")
                    installed = make_artifact_bundle(root / "installed")
                    for app in (source, installed):
                        (app / "Contents" / "MacOS" / "MacScope").write_bytes(
                            b"main-v1"
                        )
                        (
                            app
                            / "Contents"
                            / "XPCServices"
                            / "AnalysisWorkerXPCService.xpc"
                            / "Contents"
                            / "MacOS"
                            / "AnalysisWorkerXPCService"
                        ).write_bytes(b"worker-v1")
                        (
                            app
                            / "Contents"
                            / "XPCServices"
                            / "AIAgentWorkerXPCService.xpc"
                            / "Contents"
                            / "MacOS"
                            / "AIAgentWorkerXPCService"
                        ).write_bytes(b"ai-worker-v1")
                    (installed / relative_path).write_bytes(b"drifted")

                    errors = validator(source, installed)

                self.assertTrue(
                    any(drifted_product in error and "SHA-256" in error for error in errors),
                    errors,
                )

    def test_install_equality_rejects_every_closed_bundle_drift_class(self) -> None:
        module = load_guard_module()
        validator = getattr(module, "validate_installed_app_matches_source", None)
        self.assertIsNotNone(validator)

        def mutate_ordinary_resource(app: Path) -> None:
            (app / "Contents/Resources/ordinary.txt").write_bytes(b"installed-drift")

        def mutate_launch_agent(app: Path) -> None:
            (app / "Contents/MacOS/ShellBrokerLaunchAgent").write_bytes(
                b"installed-launch-agent-drift"
            )

        def mutate_nested_info_plist(app: Path) -> None:
            path = (
                app
                / "Contents/XPCServices/AnalysisWorkerXPCService.xpc/Contents/Info.plist"
            )
            with path.open("rb") as stream:
                value = plistlib.load(stream)
            value["MacScopeMutationCanary"] = "installed-only"
            with path.open("wb") as stream:
                plistlib.dump(value, stream)

        def mutate_code_resources(app: Path) -> None:
            path = app / "Contents/_CodeSignature/CodeResources"
            path.write_bytes(b"mutated-code-resources\n")

        def mutate_file_mode(app: Path) -> None:
            (app / "Contents/Resources/ordinary.txt").chmod(0o600)

        def mutate_directory_entry(app: Path) -> None:
            (app / "Contents/Resources/installed-only-directory").mkdir()

        cases = (
            (
                "ordinary resource",
                mutate_ordinary_resource,
                "bundle SHA-256",
                "bundle_sha256",
            ),
            (
                "ShellBrokerLaunchAgent",
                mutate_launch_agent,
                "bundle SHA-256",
                "bundle_sha256",
            ),
            (
                "nested Info.plist",
                mutate_nested_info_plist,
                "bundle SHA-256",
                "bundle_sha256",
            ),
            (
                "CodeResources",
                mutate_code_resources,
                "bundle SHA-256",
                "bundle_sha256",
            ),
            (
                "file mode",
                mutate_file_mode,
                "closed-tree SHA-256",
                "closed_tree_sha256",
            ),
            (
                "directory entry",
                mutate_directory_entry,
                "closed-tree SHA-256",
                "closed_tree_sha256",
            ),
        )
        for label, mutation, expected_error, changed_identity in cases:
            with self.subTest(drift=label):
                with tempfile.TemporaryDirectory() as temporary_directory:
                    root = Path(temporary_directory)
                    source = make_artifact_bundle(root / "source")
                    installed = make_artifact_bundle(root / "installed")
                    for app in (source, installed):
                        resources = app / "Contents/Resources"
                        resources.mkdir(exist_ok=True)
                        ordinary = resources / "ordinary.txt"
                        ordinary.write_bytes(b"ordinary-resource-v1")
                        ordinary.chmod(0o644)
                        (app / "Contents/MacOS/ShellBrokerLaunchAgent").write_bytes(
                            b"launch-agent-v1"
                        )

                    # The signing fixture remains favorable after every physical
                    # mutation.  The source-equality boundary must independently
                    # reject the drift instead of trusting signing success.
                    mutation(installed)
                    self.assertEqual(
                        module.validate_app_bundle(
                            installed, "Release", ArtifactFixtureRunner()
                        ),
                        [],
                    )

                    errors = validator(source, installed)
                    authority, collected_errors = (
                        module.collect_installed_source_equality(source, installed)
                    )

                self.assertTrue(
                    any(expected_error in error for error in errors),
                    errors,
                )
                self.assertEqual(collected_errors, errors)
                self.assertIsNotNone(authority)
                self.assertNotEqual(
                    authority[f"release_{changed_identity}"],
                    authority[f"installed_{changed_identity}"],
                )
                if changed_identity == "closed_tree_sha256":
                    self.assertEqual(
                        authority["release_bundle_sha256"],
                        authority["installed_bundle_sha256"],
                    )

    def test_source_app_bundle_cli_requires_installed_app_bundle(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            source = make_artifact_bundle(Path(temporary_directory))
            result = subprocess.run(
                [
                    "/usr/bin/python3",
                    str(GUARD),
                    "--source-app-bundle",
                    str(source),
                ],
                check=False,
                capture_output=True,
                text=True,
            )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("--source-app-bundle requires --app-bundle", result.stderr)

    def test_rejects_missing_embedded_analysis_worker(self) -> None:
        module = load_guard_module()
        with tempfile.TemporaryDirectory() as temporary_directory:
            app = make_artifact_bundle(Path(temporary_directory))
            worker = (
                app
                / "Contents"
                / "XPCServices"
                / "AnalysisWorkerXPCService.xpc"
            )
            worker.rename(worker.with_suffix(".missing"))

            errors = module.validate_app_bundle(
                app, "Release", ArtifactFixtureRunner()
            )

        self.assertTrue(
            any("AnalysisWorkerXPCService.xpc" in error for error in errors),
            errors,
        )

    def test_rejects_missing_embedded_ai_worker(self) -> None:
        module = load_guard_module()
        with tempfile.TemporaryDirectory() as temporary_directory:
            app = make_artifact_bundle(Path(temporary_directory))
            worker = (
                app
                / "Contents"
                / "XPCServices"
                / "AIAgentWorkerXPCService.xpc"
            )
            worker.rename(worker.with_suffix(".missing"))

            errors = module.validate_app_bundle(
                app, "Release", ArtifactFixtureRunner()
            )

        self.assertTrue(
            any("AIAgentWorkerXPCService.xpc" in error for error in errors),
            errors,
        )

    def test_rejects_artifact_signature_identity_runtime_and_architecture_drift(self) -> None:
        module = load_guard_module()
        accepted_details = """\
Identifier=org.macscope.app
CodeDirectory v=20500 size=842 flags=0x10000(runtime) hashes=16+7 location=embedded
Authority=Apple Development: MacScope Developer (CERT000000)
Authority=Apple Worldwide Developer Relations Certification Authority
Authority=Apple Root CA
TeamIdentifier=TEAM000000
"""
        mutations = {
            "strict signature verification": (
                "verify",
                "app",
                {"returncode": 1, "stderr": "invalid signature"},
                "strict/deep",
            ),
            "Apple Development authority": (
                "details",
                "app",
                {"stderr": accepted_details.replace(
                    "Apple Development: MacScope Developer (CERT000000)",
                    "adhoc",
                )},
                "Apple Development",
            ),
            "team identifier": (
                "details",
                "app",
                {
                    "stderr": accepted_details.replace(
                        "TEAM000000", "BADTEAM123", 1
                    ).replace(
                        "TeamIdentifier=TEAM000000",
                        "TeamIdentifier=BADTEAM123",
                    )
                },
                "TeamIdentifier",
            ),
            "hardened runtime": (
                "details",
                "app",
                {"stderr": accepted_details.replace("0x10000(runtime)", "0x0(none)")},
                "hardened runtime",
            ),
            "signed app identifier": (
                "details",
                "app",
                {"stderr": accepted_details.replace(
                    "Identifier=org.macscope.app",
                    "Identifier=org.macscope.app.unstable",
                )},
                "Identifier",
            ),
            "arm64-only executable": (
                "architecture",
                "worker",
                {"stdout": "x86_64 arm64\n"},
                "arm64-only",
            ),
            "macOS 27.0 minimum deployment": (
                "deployment",
                "worker",
                {"stdout": "    minos 26.4\n      sdk 27.0\n"},
                "minimum macOS version",
            ),
            "certificate-backed designated requirement": (
                "requirements",
                "worker",
                {"stderr": 'designated => cdhash H"0123456789abcdef"\n'},
                "certificate-backed",
            ),
        }

        for name, (action, target, result, expected_error) in mutations.items():
            with self.subTest(name=name):
                with tempfile.TemporaryDirectory() as temporary_directory:
                    app = make_artifact_bundle(Path(temporary_directory))
                    runner = ArtifactFixtureRunner()
                    runner.override(action, target, **result)

                    errors = module.validate_app_bundle(app, "Release", runner)

                self.assertTrue(
                    any(expected_error in error for error in errors),
                    errors,
                )

    def test_rejects_worker_bundle_or_signed_identifier_drift(self) -> None:
        module = load_guard_module()
        with tempfile.TemporaryDirectory() as temporary_directory:
            app = make_artifact_bundle(Path(temporary_directory))
            worker_plist = (
                app
                / "Contents"
                / "XPCServices"
                / "AnalysisWorkerXPCService.xpc"
                / "Contents"
                / "Info.plist"
            )
            with worker_plist.open("wb") as stream:
                plistlib.dump(
                    {
                        "CFBundleIdentifier": "org.macscope.app.OtherWorker",
                        "CFBundleExecutable": "AnalysisWorkerXPCService",
                    },
                    stream,
                )
            runner = ArtifactFixtureRunner()
            runner.override(
                "details",
                "worker",
                stderr="""\
Identifier=org.macscope.app.OtherWorker
CodeDirectory v=20500 flags=0x10000(runtime)
Authority=Apple Development: MacScope Developer (CERT000000)
TeamIdentifier=TEAM000000
""",
            )

            errors = module.validate_app_bundle(app, "Release", runner)

        self.assertTrue(any("CFBundleIdentifier" in error for error in errors), errors)
        self.assertTrue(any("signed Identifier" in error for error in errors), errors)

    def test_accepts_exact_designated_requirement_with_flexible_whitespace_and_order(self) -> None:
        module = load_guard_module()
        signer = "Apple Development: MacScope Developer (CERT000000)"
        for target, identifier in (
            ("app", "org.macscope.app"),
            ("worker", "org.macscope.app.AnalysisWorker"),
        ):
            with self.subTest(target=target):
                with tempfile.TemporaryDirectory() as temporary_directory:
                    app = make_artifact_bundle(Path(temporary_directory))
                    runner = ArtifactFixtureRunner()
                    runner.override(
                        "requirements",
                        target,
                        stderr=(
                            "designated   =>\n"
                            "  certificate  1 [ field.1.2.840.113635.100.6.2.1 ] exists\n"
                            "  and certificate leaf [ subject.CN ] = "
                            f'"{signer}"\n'
                            f'  and identifier    "{identifier}"\n'
                            "  and anchor   apple   generic\n"
                        ),
                    )

                    errors = module.validate_app_bundle(app, "Release", runner)

                self.assertEqual(errors, [])

    def test_accepts_xcode_27_requirement_comment_and_separate_diagnostic(self) -> None:
        module = load_guard_module()
        signer = "Apple Development: MacScope Developer (CERT000000)"
        with tempfile.TemporaryDirectory() as temporary_directory:
            app = make_artifact_bundle(Path(temporary_directory))
            runner = ArtifactFixtureRunner(configuration="Debug")
            for target, identifier in (
                ("app", "org.macscope.app"),
                ("worker", "org.macscope.app.AnalysisWorker"),
                ("ai_worker", "org.macscope.app.AIAgentWorker"),
                ("native_decompiler", "org.macscope.app.NativeDecompiler"),
                ("shell_broker", "org.macscope.app.ShellBroker"),
            ):
                runner.override(
                    "requirements",
                    target,
                    stdout=(
                        f'designated => identifier "{identifier}" and anchor apple '
                        "generic and certificate leaf[subject.CN] = "
                        f'"{signer}" and certificate '
                        "1[field.1.2.840.113635.100.6.2.1] /* exists */\n"
                    ),
                    stderr="Executable=/tmp/Product\n",
                )

            errors = module.validate_app_bundle(app, "Debug", runner)

        self.assertEqual(errors, [])

    def test_rejects_nonconjunctive_or_noncanonical_designated_requirements(self) -> None:
        module = load_guard_module()
        signer = "Apple Development: MacScope Developer (CERT000000)"
        intermediate = "certificate 1[field.1.2.840.113635.100.6.2.1] exists"
        for target, identifier in (
            ("app", "org.macscope.app"),
            ("worker", "org.macscope.app.AnalysisWorker"),
        ):
            leaf = f'certificate leaf[subject.CN] = "{signer}"'
            identifier_clause = f'identifier "{identifier}"'
            mutations = {
                "disjunction": (
                    f"anchor apple generic or {identifier_clause} and {leaf} "
                    f"and {intermediate}"
                ),
                "missing intermediate": (
                    f"anchor apple generic and {identifier_clause} and {leaf}"
                ),
                "extra clause": (
                    f"anchor apple generic and {identifier_clause} and {leaf} "
                    f"and {intermediate} and true"
                ),
                "duplicate identifier": (
                    f"anchor apple generic and {identifier_clause} and "
                    f"{identifier_clause} and {leaf} and {intermediate}"
                ),
                "wrong intermediate oid": (
                    f"anchor apple generic and {identifier_clause} and {leaf} and "
                    "certificate 1[field.1.2.840.113635.100.6.2.9] exists"
                ),
                "unexpected intermediate operator": (
                    f"anchor apple generic and {identifier_clause} and {leaf} and "
                    "certificate 1[field.1.2.840.113635.100.6.2.1] = true"
                ),
            }
            for name, expression in mutations.items():
                with self.subTest(target=target, name=name):
                    with tempfile.TemporaryDirectory() as temporary_directory:
                        app = make_artifact_bundle(Path(temporary_directory))
                        runner = ArtifactFixtureRunner()
                        runner.override(
                            "requirements",
                            target,
                            stderr=f"designated => {expression}\n",
                        )

                        errors = module.validate_app_bundle(app, "Release", runner)

                    self.assertTrue(
                        any("exact conjunctive designated requirement" in error for error in errors),
                        errors,
                    )

    def test_rejects_leaf_hash_designated_requirement(self) -> None:
        module = load_guard_module()
        with tempfile.TemporaryDirectory() as temporary_directory:
            app = make_artifact_bundle(Path(temporary_directory))
            runner = ArtifactFixtureRunner()
            runner.override(
                "requirements",
                "app",
                stderr=(
                    'designated => anchor apple generic and identifier '
                    '"org.macscope.app" and certificate leaf = '
                    'H"0123456789abcdef"\n'
                ),
            )

            errors = module.validate_app_bundle(app, "Release", runner)

        self.assertTrue(any("designated requirement" in error for error in errors), errors)

    def test_rejects_designated_requirement_subject_not_matching_authority(self) -> None:
        module = load_guard_module()
        with tempfile.TemporaryDirectory() as temporary_directory:
            app = make_artifact_bundle(Path(temporary_directory))
            runner = ArtifactFixtureRunner()
            runner.override(
                "requirements",
                "app",
                stderr=(
                    'designated => anchor apple generic and identifier '
                    '"org.macscope.app" and certificate leaf[subject.CN] = '
                    '"Apple Development: Different Developer (OTHERID123)" and '
                    'certificate 1[field.1.2.840.113635.100.6.2.1] exists\n'
                ),
            )

            errors = module.validate_app_bundle(app, "Release", runner)

        self.assertTrue(any("does not match signing Authority" in error for error in errors), errors)

    def test_rejects_app_and_worker_signed_by_different_development_certificates(self) -> None:
        module = load_guard_module()
        with tempfile.TemporaryDirectory() as temporary_directory:
            app = make_artifact_bundle(Path(temporary_directory))
            runner = ArtifactFixtureRunner()
            runner.override(
                "details",
                "worker",
                stderr="""\
Identifier=org.macscope.app.AnalysisWorker
CodeDirectory v=20500 flags=0x10000(runtime)
Authority=Apple Development: Different Developer (OTHERID123)
Authority=Apple Worldwide Developer Relations Certification Authority
Authority=Apple Root CA
TeamIdentifier=TEAM000000
""",
            )
            runner.override(
                "requirements",
                "worker",
                stderr=(
                    'designated => anchor apple generic and identifier '
                    '"org.macscope.app.AnalysisWorker" and '
                    'certificate leaf[subject.CN] = '
                    '"Apple Development: Different Developer (OTHERID123)" and '
                    'certificate 1[field.1.2.840.113635.100.6.2.1] exists\n'
                ),
            )

            errors = module.validate_app_bundle(app, "Release", runner)

        self.assertTrue(any("same Apple Development signer" in error for error in errors), errors)

    def test_rejects_app_and_worker_drifting_together_to_an_alternate_signer(self) -> None:
        module = load_guard_module()
        alternate_signer = "Apple Development: Different Developer (OTHERID123)"
        with tempfile.TemporaryDirectory() as temporary_directory:
            app = make_artifact_bundle(Path(temporary_directory))
            runner = ArtifactFixtureRunner()
            for target, identifier in (
                ("app", "org.macscope.app"),
                ("worker", "org.macscope.app.AnalysisWorker"),
                ("ai_worker", "org.macscope.app.AIAgentWorker"),
                ("native_decompiler", "org.macscope.app.NativeDecompiler"),
                ("shell_broker", "org.macscope.app.ShellBroker"),
            ):
                runner.override(
                    "details",
                    target,
                    stderr=(
                        f"Identifier={identifier}\n"
                        "CodeDirectory v=20500 flags=0x10000(runtime)\n"
                        f"Authority={alternate_signer}\n"
                        "Authority=Apple Worldwide Developer Relations "
                        "Certification Authority\n"
                        "Authority=Apple Root CA\n"
                        "TeamIdentifier=TEAM000000\n"
                    ),
                )
                runner.override(
                    "requirements",
                    target,
                    stderr=(
                        "designated => anchor apple generic and identifier "
                        f'"{identifier}" and certificate leaf[subject.CN] = '
                        f'"{alternate_signer}" and certificate '
                        "1[field.1.2.840.113635.100.6.2.1] exists\n"
                    ),
                )

            errors = module.validate_app_bundle(app, "Release", runner)

        self.assertTrue(
            any("MacScope Developer (CERT000000)" in error for error in errors),
            errors,
        )

    def test_release_allows_only_optional_get_task_allow_entitlement(self) -> None:
        module = load_guard_module()
        get_task_allow = plistlib.dumps(
            {"com.apple.security.get-task-allow": True}
        ).decode("utf-8")

        for target in ("app", "worker"):
            with self.subTest(target=target, entitlement="get-task-allow"):
                with tempfile.TemporaryDirectory() as temporary_directory:
                    app = make_artifact_bundle(Path(temporary_directory))
                    runner = ArtifactFixtureRunner()
                    runner.override("entitlements", target, stdout=get_task_allow)

                    errors = module.validate_app_bundle(app, "Release", runner)

                self.assertEqual(errors, [])

            with self.subTest(target=target, entitlement="extra"):
                with tempfile.TemporaryDirectory() as temporary_directory:
                    app = make_artifact_bundle(Path(temporary_directory))
                    runner = ArtifactFixtureRunner()
                    runner.override(
                        "entitlements",
                        target,
                        stdout=plistlib.dumps(
                            {
                                "com.apple.security.get-task-allow": True,
                                "com.apple.security.app-sandbox": True,
                            }
                        ).decode("utf-8"),
                    )

                    errors = module.validate_app_bundle(app, "Release", runner)

                self.assertTrue(
                    any("Release entitlements" in error for error in errors),
                    errors,
                )

    def test_debug_allows_only_optional_get_task_allow_entitlement(self) -> None:
        module = load_guard_module()
        get_task_allow = plistlib.dumps(
            {"com.apple.security.get-task-allow": True}
        ).decode("utf-8")

        with tempfile.TemporaryDirectory() as temporary_directory:
            app = make_artifact_bundle(Path(temporary_directory))
            accepted_runner = ArtifactFixtureRunner(configuration="Debug")
            accepted_runner.override("entitlements", "app", stdout=get_task_allow)
            accepted_runner.override("entitlements", "worker", stdout=get_task_allow)
            self.assertEqual(
                module.validate_app_bundle(app, "Debug", accepted_runner), []
            )

            rejected_runner = ArtifactFixtureRunner(configuration="Debug")
            rejected_runner.override(
                "entitlements",
                "app",
                stdout=plistlib.dumps(
                    {
                        "com.apple.security.get-task-allow": True,
                        "com.apple.security.app-sandbox": True,
                    }
                ).decode("utf-8"),
            )
            errors = module.validate_app_bundle(app, "Debug", rejected_runner)

        self.assertTrue(any("Debug entitlements" in error for error in errors), errors)

    def test_debug_xcode_test_host_profile_is_exact_and_debug_only(self) -> None:
        module = load_guard_module()
        self.assertEqual(
            module.EXPECTED_XCODE_TEST_HOST_ENTITLEMENTS,
            XCODE_TEST_HOST_ENTITLEMENTS_FIXTURE,
        )

        with tempfile.TemporaryDirectory() as temporary_directory:
            app = make_artifact_bundle(Path(temporary_directory))
            add_xcode_test_host_artifacts(app)
            accepted_runner = xcode_test_host_fixture_runner()
            self.assertEqual(
                module.validate_app_bundle(
                    app,
                    "Debug",
                    accepted_runner,
                    xcode_test_host=True,
                ),
                [],
            )

            drifted = dict(XCODE_TEST_HOST_ENTITLEMENTS_FIXTURE)
            drifted["com.apple.security.temporary-exception.mach-lookup.global-name"] = [
                "com.apple.testmanagerd",
                "com.apple.dt.testmanagerd.runner",
            ]
            rejected_runner = xcode_test_host_fixture_runner()
            rejected_runner.override(
                "entitlements",
                "ai_worker",
                stdout=plistlib.dumps(drifted).decode("utf-8"),
            )
            errors = module.validate_app_bundle(
                app,
                "Debug",
                rejected_runner,
                xcode_test_host=True,
            )

        self.assertTrue(any("exactly match" in error for error in errors), errors)
        self.assertTrue(
            any("AIAgentWorkerXPCService.xpc" in error for error in errors),
            errors,
        )
        self.assertEqual(
            module.validate_app_bundle(
                Path("/does/not/matter"),
                "Release",
                xcode_test_host=True,
            ),
            ["the Xcode test-host entitlement profile is permitted only for Debug artifacts"],
        )

        missing_app = subprocess.run(
            ["python3", "-B", str(GUARD), "--xcode-test-host-entitlements"],
            text=True,
            capture_output=True,
            check=False,
        )
        self.assertEqual(missing_app.returncode, 2)
        self.assertIn("requires --app-bundle", missing_app.stderr)

    def test_debug_xcode_test_host_requires_both_observed_nested_products(self) -> None:
        module = load_guard_module()
        for missing_relative, expected_label in (
            ("Contents/PlugIns/CoreTests.xctest", "CoreTests.xctest"),
            ("Contents/MacOS/ShellBrokerLaunchAgent", "ShellBrokerLaunchAgent"),
        ):
            with self.subTest(product=expected_label):
                with tempfile.TemporaryDirectory() as temporary_directory:
                    app = make_artifact_bundle(Path(temporary_directory))
                    core_tests, launch_agent = add_xcode_test_host_artifacts(app)
                    missing = app / missing_relative
                    if missing == core_tests:
                        (core_tests / "Contents/MacOS/CoreTests").unlink()
                        (core_tests / "Contents/Info.plist").unlink()
                        (
                            core_tests / "Contents/_CodeSignature/CodeResources"
                        ).unlink()
                        (core_tests / "Contents/MacOS").rmdir()
                        (core_tests / "Contents/_CodeSignature").rmdir()
                        (core_tests / "Contents").rmdir()
                        core_tests.rmdir()
                    else:
                        self.assertEqual(missing, launch_agent)
                        launch_agent.unlink()
                    errors = module.validate_app_bundle(
                        app,
                        "Debug",
                        xcode_test_host_fixture_runner(),
                        xcode_test_host=True,
                    )
                self.assertTrue(
                    any(expected_label in error and "missing" in error for error in errors),
                    errors,
                )

    def test_debug_xcode_test_host_rejects_nested_signing_and_platform_drift(self) -> None:
        module = load_guard_module()
        products = {
            "core_tests": (
                "CoreTests.xctest",
                "org.macscope.app.CoreTests",
            ),
            "source_runner": ("SourceExecutionRunner", "org.macscope.app.SourceExecutionRunner"),
            "shell_launch_agent": (
                "ShellBrokerLaunchAgent",
                "org.macscope.app.ShellBrokerLaunchAgent",
            ),
        }
        mutations = {
            "signed identifier": (
                "details",
                lambda identifier: signed_details_fixture(identifier + ".drifted"),
                "signed Identifier",
            ),
            "hardened runtime": (
                "details",
                lambda identifier: signed_details_fixture(identifier, runtime=False),
                "hardened runtime",
            ),
            "leaf signer": (
                "details",
                lambda identifier: signed_details_fixture(
                    identifier,
                    signer="Apple Development: Different Developer (OTHERID123)",
                ),
                "leaf Authority",
            ),
            "team identifier": (
                "details",
                lambda identifier: signed_details_fixture(
                    identifier,
                    team="OTHERTEAM1",
                ),
                "TeamIdentifier",
            ),
            "designated requirement": (
                "requirements",
                lambda identifier: designated_requirement_fixture(identifier + ".drifted"),
                "designated requirement",
            ),
            "architecture": (
                "architecture",
                lambda _identifier: "x86_64\n",
                "arm64-only",
            ),
            "minimum OS": (
                "deployment",
                lambda _identifier: "platform MACOS\n    minos 26.4\n",
                "minimum macOS version",
            ),
        }
        for target, (label, identifier) in products.items():
            for mutation, (action, output, expected_error) in mutations.items():
                with self.subTest(product=label, mutation=mutation):
                    with tempfile.TemporaryDirectory() as temporary_directory:
                        app = make_artifact_bundle(Path(temporary_directory))
                        add_xcode_test_host_artifacts(app)
                        runner = xcode_test_host_fixture_runner()
                        value = output(identifier)
                        if action in {"details", "requirements"}:
                            runner.override(action, target, stderr=value)
                        else:
                            runner.override(action, target, stdout=value)
                        errors = module.validate_app_bundle(
                            app,
                            "Debug",
                            runner,
                            xcode_test_host=True,
                        )
                    self.assertTrue(
                        any(
                            label in error and expected_error in error
                            for error in errors
                        ),
                        errors,
                    )

    def test_debug_xcode_test_host_requires_empty_coretests_entitlements(self) -> None:
        module = load_guard_module()
        with tempfile.TemporaryDirectory() as temporary_directory:
            app = make_artifact_bundle(Path(temporary_directory))
            add_xcode_test_host_artifacts(app)
            runner = xcode_test_host_fixture_runner()
            runner.override(
                "entitlements",
                "core_tests",
                stdout=plistlib.dumps(
                    {"com.apple.security.get-task-allow": True}
                ).decode("utf-8"),
            )
            errors = module.validate_app_bundle(
                app,
                "Debug",
                runner,
                xcode_test_host=True,
            )
        self.assertTrue(
            any(
                "CoreTests.xctest" in error and "empty entitlement" in error
                for error in errors
            ),
            errors,
        )

    def test_debug_xcode_test_host_freezes_every_launch_agent_entitlement(self) -> None:
        module = load_guard_module()
        self.assertEqual(
            module.EXPECTED_SHELL_BROKER_LAUNCH_AGENT_ENTITLEMENTS,
            SHELL_BROKER_LAUNCH_AGENT_ENTITLEMENTS_FIXTURE,
        )
        mutations: dict[str, dict[str, object]] = {}
        for key in SHELL_BROKER_LAUNCH_AGENT_ENTITLEMENTS_FIXTURE:
            missing = dict(SHELL_BROKER_LAUNCH_AGENT_ENTITLEMENTS_FIXTURE)
            del missing[key]
            mutations[f"missing {key}"] = missing
        wrong_application_identifier = dict(
            SHELL_BROKER_LAUNCH_AGENT_ENTITLEMENTS_FIXTURE
        )
        wrong_application_identifier["com.apple.application-identifier"] = (
            "TEAM000000.org.macscope.app.OtherLaunchAgent"
        )
        mutations["wrong application identifier"] = wrong_application_identifier
        wrong_get_task_allow = dict(SHELL_BROKER_LAUNCH_AGENT_ENTITLEMENTS_FIXTURE)
        wrong_get_task_allow["com.apple.security.get-task-allow"] = False
        mutations["disabled get-task-allow"] = wrong_get_task_allow
        wrong_read_scope = dict(SHELL_BROKER_LAUNCH_AGENT_ENTITLEMENTS_FIXTURE)
        wrong_read_scope[
            "com.apple.security.temporary-exception.files.absolute-path.read-only"
        ] = ["/Applications"]
        mutations["narrowed absolute read scope"] = wrong_read_scope
        wrong_mach_names = dict(SHELL_BROKER_LAUNCH_AGENT_ENTITLEMENTS_FIXTURE)
        wrong_mach_names[
            "com.apple.security.temporary-exception.mach-lookup.global-name"
        ] = ["com.apple.testmanagerd", "com.apple.dt.testmanagerd.runner"]
        mutations["missing mach lookup name"] = wrong_mach_names
        unexpected = dict(SHELL_BROKER_LAUNCH_AGENT_ENTITLEMENTS_FIXTURE)
        unexpected["com.apple.security.app-sandbox"] = True
        mutations["unexpected entitlement"] = unexpected

        for mutation, profile in mutations.items():
            with self.subTest(mutation=mutation):
                with tempfile.TemporaryDirectory() as temporary_directory:
                    app = make_artifact_bundle(Path(temporary_directory))
                    add_xcode_test_host_artifacts(app)
                    runner = xcode_test_host_fixture_runner()
                    runner.override(
                        "entitlements",
                        "shell_launch_agent",
                        stdout=plistlib.dumps(profile).decode("utf-8"),
                    )
                    errors = module.validate_app_bundle(
                        app,
                        "Debug",
                        runner,
                        xcode_test_host=True,
                    )
                self.assertTrue(
                    any(
                        "ShellBrokerLaunchAgent" in error
                        and "exactly match" in error
                        for error in errors
                    ),
                    errors,
                )

    def test_debug_xcode_test_host_refuses_unobserved_optional_plugin(self) -> None:
        module = load_guard_module()
        with tempfile.TemporaryDirectory() as temporary_directory:
            app = make_artifact_bundle(Path(temporary_directory))
            add_xcode_test_host_artifacts(app)
            add_plugin_artifact(app)
            errors = module.validate_app_bundle(
                app,
                "Debug",
                xcode_test_host_fixture_runner(),
                xcode_test_host=True,
            )
        self.assertTrue(
            any(
                "exactly the four approved XPC services" in error
                and "PluginXPCService.xpc" in error
                for error in errors
            ),
            errors,
        )

    def test_debug_xcode_test_host_profile_cannot_apply_to_source_comparison(self) -> None:
        result = subprocess.run(
            [
                "python3",
                "-B",
                str(GUARD),
                "--app-bundle",
                "/does/not/matter/MacScope.app",
                "--source-app-bundle",
                "/does/not/matter/source/MacScope.app",
                "--configuration",
                "Debug",
                "--xcode-test-host-entitlements",
            ],
            text=True,
            capture_output=True,
            check=False,
        )
        self.assertEqual(result.returncode, 2)
        self.assertIn(
            "cannot be combined with --source-app-bundle",
            result.stderr,
        )

    def test_validate_rebuild_runs_artifact_signing_guard_for_configuration(self) -> None:
        script = (
            REPOSITORY_ROOT / "MacScope" / "Scripts" / "validate_rebuild.sh"
        ).read_text(encoding="utf-8")

        self.assertIn(
            'check_local_signing_policy.py" --app-bundle "$APP_BUNDLE"',
            script,
        )
        self.assertIn('--configuration "$CONFIGURATION"', script)

    def test_authored_info_plists_defer_to_product_bundle_identifier(self) -> None:
        for relative_path in (
            "MacScope/Resources/Info.plist",
            "MacScope/AnalysisWorkerService/Info.plist",
            "MacScope/AIAgentWorkerService/Info.plist",
        ):
            with self.subTest(relative_path=relative_path):
                with (REPOSITORY_ROOT / relative_path).open("rb") as stream:
                    metadata = plistlib.load(stream)
                self.assertEqual(
                    metadata["CFBundleIdentifier"],
                    "$(PRODUCT_BUNDLE_IDENTIFIER)",
                )

    def test_native_decompiler_target_is_mandatory_and_source_policy_protected(self) -> None:
        module = load_guard_module()
        current = (REPOSITORY_ROOT / "MacScope" / "project.yml").read_text(
            encoding="utf-8"
        )
        candidate = current
        self.assertEqual(module.validate_project_settings(candidate), [])

        mutations = {
            "deploymentTarget": ('    deploymentTarget: "27.0"', '    deploymentTarget: "26.4"'),
            "PRODUCT_BUNDLE_IDENTIFIER": (
                "PRODUCT_BUNDLE_IDENTIFIER: org.macscope.app.NativeDecompiler",
                "PRODUCT_BUNDLE_IDENTIFIER: org.macscope.app.NativeDecompiler.unstable",
            ),
            "INFOPLIST_FILE": (
                "INFOPLIST_FILE: NativeDecompilerXPCService/Info.plist",
                "INFOPLIST_FILE: NativeDecompilerXPCService/Other.plist",
            ),
            "GENERATE_INFOPLIST_FILE": (
                "GENERATE_INFOPLIST_FILE: NO",
                "GENERATE_INFOPLIST_FILE: YES",
            ),
        }
        target_start = candidate.index("  NativeDecompilerXPCService:\n")
        target_end = candidate.index("  CoreTests:\n", target_start)
        target_block = candidate[target_start:target_end]
        missing_errors = module.validate_project_settings(
            candidate[:target_start] + candidate[target_end:]
        )
        self.assertTrue(
            any("NativeDecompilerXPCService" in error for error in missing_errors),
            missing_errors,
        )
        for expected_setting, (accepted, rejected) in mutations.items():
            with self.subTest(setting=expected_setting):
                self.assertIn(accepted, target_block)
                mutated = candidate.replace(
                    target_block,
                    target_block.replace(accepted, rejected, 1),
                    1,
                )
                errors = module.validate_project_settings(mutated)
                self.assertTrue(
                    any(
                        "NativeDecompilerXPCService" in error
                        and expected_setting in error
                        for error in errors
                    ),
                    errors,
                )

        signing_override = target_block.replace(
            "      base:\n",
            "      base:\n"
            "        CODE_SIGN_IDENTITY: -\n"
            "        DEVELOPMENT_TEAM: BADTEAM123\n"
            "        ENABLE_HARDENED_RUNTIME: NO\n",
            1,
        )
        errors = module.validate_project_settings(
            candidate.replace(target_block, signing_override, 1)
        )
        for expected_setting in (
            "CODE_SIGN_IDENTITY",
            "DEVELOPMENT_TEAM",
            "ENABLE_HARDENED_RUNTIME",
        ):
            self.assertTrue(
                any(
                    "NativeDecompilerXPCService" in error
                    and expected_setting in error
                    for error in errors
                ),
                errors,
            )

    def test_native_decompiler_target_requires_target_aware_always_run_guard(self) -> None:
        module = load_guard_module()
        current = (REPOSITORY_ROOT / "MacScope" / "project.yml").read_text(
            encoding="utf-8"
        )
        candidate = current
        command = (
            '/usr/bin/python3 "$SRCROOT/../Scripts/check_local_signing_policy.py" '
            '--build-environment --target "$TARGET_NAME"'
        )

        self.assertEqual(module.validate_app_target_guard(candidate), [])
        target_start = candidate.index("  NativeDecompilerXPCService:\n")
        target_end = candidate.index("  CoreTests:\n", target_start)
        target_block = candidate[target_start:target_end]
        mutated = candidate.replace(
            target_block,
            target_block.replace(command, "# native decompiler guard removed", 1),
            1,
        )
        errors = module.validate_app_target_guard(mutated)
        self.assertTrue(
            any("NativeDecompilerXPCService" in error for error in errors),
            errors,
        )

    def test_native_decompiler_effective_and_active_build_settings_are_exact(self) -> None:
        module = load_guard_module()
        settings = """\
Build settings for action build and target NativeDecompilerXPCService:
    AD_HOC_CODE_SIGNING_ALLOWED = NO
    CODE_SIGNING_ALLOWED = YES
    CODE_SIGNING_REQUIRED = YES
    CODE_SIGN_STYLE = Manual
    CODE_SIGN_IDENTITY = Apple Development: MacScope Developer (CERT000000)
    PROVISIONING_PROFILE =
    PROVISIONING_PROFILE_SPECIFIER =
    DEVELOPMENT_TEAM = TEAM000000
    ENABLE_HARDENED_RUNTIME = YES
    MACOSX_DEPLOYMENT_TARGET = 27.0
    PRODUCT_BUNDLE_IDENTIFIER = org.macscope.app.NativeDecompiler
    GENERATE_INFOPLIST_FILE = NO
    INFOPLIST_FILE = NativeDecompilerXPCService/Info.plist
    CODE_SIGN_INJECT_BASE_ENTITLEMENTS = YES
    CODE_SIGN_ENTITLEMENTS =
    OTHER_CODE_SIGN_FLAGS =
"""
        self.assertEqual(
            module.validate_effective_settings(
                settings, "Release", "NativeDecompilerXPCService"
            ),
            [],
        )

        environment = {
            key: value
            for key, value in module.parse_target_build_settings(
                settings, "NativeDecompilerXPCService"
            ).items()
        }
        environment.update(
            {
                "TARGET_NAME": "NativeDecompilerXPCService",
                "CONFIGURATION": "Release",
            }
        )
        self.assertEqual(
            module.validate_build_environment(
                environment, "NativeDecompilerXPCService"
            ),
            [],
        )
        for key, rejected in {
            "CODE_SIGN_IDENTITY": "-",
            "DEVELOPMENT_TEAM": "BADTEAM123",
            "ENABLE_HARDENED_RUNTIME": "NO",
            "MACOSX_DEPLOYMENT_TARGET": "26.4",
            "PRODUCT_BUNDLE_IDENTIFIER": "org.macscope.app.OtherNative",
            "INFOPLIST_FILE": "NativeDecompilerXPCService/Other.plist",
            "OTHER_CODE_SIGN_FLAGS": "--deep",
        }.items():
            with self.subTest(setting=key):
                mutated = dict(environment)
                mutated[key] = rejected
                errors = module.validate_build_environment(
                    mutated, "NativeDecompilerXPCService"
                )
                self.assertTrue(any(key in error for error in errors), errors)

    def test_native_decompiler_is_a_mandatory_signed_installed_product(self) -> None:
        module = load_guard_module()
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            source = make_artifact_bundle(root / "source")
            installed = make_artifact_bundle(root / "installed")
            runner = ArtifactFixtureRunner()

            self.assertEqual(module.validate_app_bundle(source, "Release", runner), [])
            verified = {
                Path(call[-1]).name
                for call in runner.calls
                if "--verify" in call and "--deep" in call and "--strict" in call
            }
            self.assertIn("NativeDecompilerXPCService.xpc", verified)

            entitlement_runner = ArtifactFixtureRunner()
            entitlement_runner.override(
                "entitlements",
                "native_decompiler",
                stdout=plistlib.dumps(
                    {"com.apple.security.app-sandbox": True}
                ).decode("utf-8"),
            )
            entitlement_errors = module.validate_app_bundle(
                source, "Release", entitlement_runner
            )
            self.assertTrue(
                any(
                    "NativeDecompilerXPCService.xpc" in error
                    and "Release entitlements" in error
                    for error in entitlement_errors
                ),
                entitlement_errors,
            )

            native_relative = Path(
                "Contents/XPCServices/NativeDecompilerXPCService.xpc/Contents/"
                "MacOS/NativeDecompilerXPCService"
            )
            for app in (source, installed):
                (app / "Contents/MacOS/MacScope").write_bytes(b"main-v1")
                (app / native_relative).write_bytes(b"native-v1")
            (installed / native_relative).write_bytes(b"native-drifted")
            equality_errors = module.validate_installed_app_matches_source(
                source, installed
            )
            self.assertTrue(
                any(
                    "NativeDecompilerXPCService.xpc executable" in error
                    and "SHA-256" in error
                    for error in equality_errors
                ),
                equality_errors,
            )

            native_bundle = (
                source
                / "Contents"
                / "XPCServices"
                / "NativeDecompilerXPCService.xpc"
            )
            native_bundle.rename(native_bundle.with_suffix(".missing"))
            missing_errors = module.validate_app_bundle(
                source, "Release", ArtifactFixtureRunner()
            )
            self.assertTrue(
                any("NativeDecompilerXPCService.xpc" in error for error in missing_errors),
                missing_errors,
            )

    def test_build_and_run_postvalidates_the_selected_configuration(self) -> None:
        script = (REPOSITORY_ROOT / "MacScope" / "script" / "build_and_run.sh").read_text(
            encoding="utf-8"
        )
        validation = (
            '/usr/bin/python3 "$ROOT_DIR/../Scripts/check_local_signing_policy.py" '
            '--app-bundle "$APP_BUNDLE" --configuration "$CONFIGURATION"'
        )

        self.assertEqual(script.count(validation), 1)
        self.assertLess(script.index("xcrun xcodebuild build"), script.index(validation))


class NativeCIEventAuthorityTests(unittest.TestCase):
    def workflow(self) -> str:
        return (REPOSITORY_ROOT / ".github/workflows/ci.yml").read_text()

    def event_script(self) -> str:
        marker = "      - name: Bind exact event source\n"
        workflow = self.workflow()
        self.assertIn(marker, workflow, "CI must bind its event, not main")
        step = workflow.split(marker, 1)[1].split("\n      - name:", 1)[0]
        return "\n".join(line[10:] for line in step.split("        run: |\n", 1)[1].splitlines())

    def test_event_authority_accepts_main_branch_and_pr_merge_commits(self) -> None:
        script = self.event_script()
        with tempfile.TemporaryDirectory(prefix="native-ci-event-") as directory:
            root = Path(directory)
            remote = root / "canonical"
            checkout = root / "checkout"
            def git(*args: str, cwd: Path = remote) -> str:
                return subprocess.run(["git", *args], cwd=cwd, check=True,
                                      capture_output=True, text=True).stdout.strip()
            remote.mkdir()
            git("init", "-b", "main")
            git("config", "user.name", "CI Fixture")
            git("config", "user.email", "ci@example.invalid")
            git("commit", "--allow-empty", "-m", "main")
            main = git("rev-parse", "HEAD")
            git("switch", "-c", "feature")
            git("commit", "--allow-empty", "-m", "feature")
            branch = git("rev-parse", "HEAD")
            git("switch", "main")
            git("merge", "--no-ff", "feature", "-m", "PR merge")
            merge = git("rev-parse", "HEAD")
            git("update-ref", "refs/pull/7/merge", merge)
            git("update-ref", "refs/heads/main", main)
            git("clone", str(remote), str(checkout), cwd=root)
            for attempt, (name, sha, ref) in enumerate((("push", main, "refs/heads/main"),
                                   ("workflow_dispatch", branch, "refs/heads/feature"),
                                   ("pull_request", merge, "refs/pull/7/merge")), 1):
                with self.subTest(event=name):
                    git("checkout", "--detach", sha, cwd=checkout)
                    result = subprocess.run(["bash", "-eu", "-o", "pipefail", "-c", script],
                        cwd=checkout, env={**os.environ, "GITHUB_SHA": sha,
                                         "GITHUB_REF": ref, "GITHUB_EVENT_NAME": name,
                                         "GITHUB_RUN_ID": "123", "GITHUB_RUN_ATTEMPT": str(attempt)},
                        capture_output=True, text=True, timeout=10)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(git("rev-parse", "refs/remotes/origin/ci-event", cwd=checkout), sha)
                    self.assertEqual(git("branch", "--show-current", cwd=checkout), f"ci-event-123-{attempt}")
                    self.assertEqual(git("rev-parse", "HEAD", cwd=checkout), sha)
            # A stale/misbound checkout must not be admitted as the event source.
            result = subprocess.run(["bash", "-eu", "-o", "pipefail", "-c", script],
                cwd=checkout, env={**os.environ, "GITHUB_SHA": main},
                capture_output=True, text=True, timeout=10)
            self.assertNotEqual(result.returncode, 0)

    def test_checkout_materializes_lfs_before_source_export_without_lfs_bandwidth(self) -> None:
        workflow = self.workflow()
        checkout = workflow.split("      - name: Checkout\n", 1)[1].split("\n      - name:", 1)[0]
        self.assertIn("          lfs: false", checkout)
        materialize = workflow.split("      - name: Materialize LFS payloads from local object stores\n", 1)[1]
        materialize = materialize.split("\n      - name:", 1)[0]
        self.assertIn("git lfs checkout", materialize)
        self.assertNotIn("git lfs pull", materialize)
        self.assertNotIn("git lfs fetch", materialize)
        self.assertLess(workflow.index("Materialize LFS payloads"), workflow.index("      - name: Build and test\n"))

    def test_personal_runner_excludes_fork_pull_requests(self) -> None:
        job = self.workflow().split("  test:\n", 1)[1].split("    steps:\n", 1)[0]
        self.assertIn("    if: github.event_name != 'pull_request' || github.event.pull_request.head.repo.full_name == github.repository", job)
        self.assertNotIn("pull_request_target:", self.workflow())

    def test_signing_guard_accepts_only_the_fork_safety_job_condition(self) -> None:
        module = load_guard_module()
        workflow = self.workflow()
        condition = "    if: github.event_name != 'pull_request' || github.event.pull_request.head.repo.full_name == github.repository"
        self.assertEqual(module.validate_ci_override(workflow), [])
        for replacement in ("", "    if: false", "    if: true", condition + "\n" + condition):
            with self.subTest(replacement=replacement):
                self.assertNotEqual(module.validate_ci_override(workflow.replace(condition, replacement)), [])

    def test_qualification_pins_expected_event_commit(self) -> None:
        self.assertIn('--integration-commit "$GITHUB_SHA"', self.workflow())

    def test_qualification_reuses_this_macs_cache_without_network_authority(self) -> None:
        workflow = self.workflow()
        cache = "$MACSCOPE_WORK_ROOT/MacScopeQualificationCache-20260920"
        self.assertIn(f'echo "MACSCOPE_DEPENDENCY_CACHE_ROOT={cache}"', workflow)
        argument = '--dependency-cache-root "$MACSCOPE_DEPENDENCY_CACHE_ROOT"'
        self.assertIn(argument, workflow)
        self.assertNotIn("--materialize-dependencies", workflow)
        module = load_guard_module()
        self.assertEqual(module.validate_ci_override(workflow), [])
        for mutation in (workflow.replace(argument, "--materialize-dependencies"),
                         workflow.replace(argument, argument + " --materialize-dependencies")):
            self.assertNotEqual(module.validate_ci_override(mutation), [])


if __name__ == "__main__":
    unittest.main()
