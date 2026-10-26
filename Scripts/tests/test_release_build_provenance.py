#!/usr/bin/env python3
"""Tests for the sealed Release-build provenance producer."""

from __future__ import annotations

import hashlib
import importlib.util
import json
import os
import plistlib
import py_compile
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
GENERATOR = REPOSITORY_ROOT / "Scripts" / "generate_release_build_provenance.py"
SOURCE_EXPORT_TOOL = REPOSITORY_ROOT / "Scripts" / "source_export_provenance.py"
SOURCE_IDENTITY_HELPER = (
    REPOSITORY_ROOT
    / "Scripts"
    / "native-decompiler-xpc"
    / "native_decompiler_source_identity.py"
)
MACHOKIT_SOURCE_IDENTITY_HELPER = (
    REPOSITORY_ROOT / "Scripts" / "machokit_source_identity.py"
)
MACHOKIT_MATERIALIZER = (
    REPOSITORY_ROOT / "Scripts" / "dependencies" / "materialize_machokit.py"
)
MACHOKIT_COMPILED_IDENTITY_VERIFIER = (
    REPOSITORY_ROOT / "Scripts" / "verify_machokit_analysis_worker_identity.py"
)
_RELEASE_ADMISSION_SPEC = importlib.util.spec_from_file_location(
    "release_fixture_publication_admission",
    REPOSITORY_ROOT / "Scripts" / "qualification" / "release_provenance_admission.py",
)
assert _RELEASE_ADMISSION_SPEC is not None and _RELEASE_ADMISSION_SPEC.loader is not None
_RELEASE_ADMISSION = importlib.util.module_from_spec(_RELEASE_ADMISSION_SPEC)
_RELEASE_ADMISSION_SPEC.loader.exec_module(_RELEASE_ADMISSION)
RELEASE_ADMISSION_SOURCE_INPUTS = _RELEASE_ADMISSION.SOURCE_INPUTS
FIXTURE_PBX = b"// deterministic fixture project\n"
APPLE_SILICON_CRITICAL_FILE_RELATIVE_PATHS = (
    "share/sleigh/specfiles/Ghidra/Processors/AARCH64/data/languages/AppleSilicon.ldefs",
    "share/sleigh/specfiles/Ghidra/Processors/AARCH64/data/languages/AARCH64_AppleSilicon.sla",
    "share/sleigh/specfiles/Ghidra/Processors/AARCH64/data/languages/AARCH64.pspec",
    "share/sleigh/specfiles/Ghidra/Processors/AARCH64/data/languages/AARCH64_apple.cspec",
)


def load_generator_module():
    if not GENERATOR.is_file():
        raise AssertionError(f"missing provenance generator: {GENERATOR}")
    specification = importlib.util.spec_from_file_location(
        "generate_release_build_provenance",
        GENERATOR,
    )
    if specification is None or specification.loader is None:
        raise AssertionError("could not load provenance generator")
    module = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(module)
    return module


def load_machokit_compiled_identity_verifier():
    specification = importlib.util.spec_from_file_location(
        "test_machokit_compiled_identity_verifier",
        MACHOKIT_COMPILED_IDENTITY_VERIFIER,
    )
    if specification is None or specification.loader is None:
        raise AssertionError("could not load MachOKit compiled-identity verifier")
    module = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(module)
    return module


def run_git(repository: Path, *arguments: str) -> str:
    result = subprocess.run(
        ["/usr/bin/git", *arguments],
        cwd=repository,
        check=True,
        capture_output=True,
        text=True,
    )
    return result.stdout.strip()


class FixtureToolRunner:
    def __init__(self) -> None:
        self.calls: list[tuple[str, ...]] = []

    def __call__(
        self,
        command: list[str],
        cwd: Path,
    ) -> subprocess.CompletedProcess[str]:
        self.calls.append(tuple(command))
        if Path(command[0]).name == "xcodegen" and command[1] == "generate":
            project_parent = (
                Path(command[command.index("-p") + 1])
                if "-p" in command
                else cwd
            )
            project = project_parent / "MacScope.xcodeproj"
            project.mkdir(parents=True, exist_ok=True)
            (project / "project.pbxproj").write_bytes(FIXTURE_PBX)
            return subprocess.CompletedProcess(command, 0, "generated\n", "")
        if tuple(command[:4]) == ("/usr/bin/xcrun", "xcodebuild", "-convert-project", "Xcode Project"):
            project = Path(command[command.index("-project") + 1])
            (project / "project.pbxproj").rename(project / "project.xcproj")
            return subprocess.CompletedProcess(command, 0, "converted\n", "")
        if (
            len(command) == 2
            and Path(command[0]).name in {"swiftc", "swift-frontend"}
            and command[1] == "--version"
        ):
            return subprocess.CompletedProcess(
                command,
                0,
                "Apple Swift version 6.4 (swiftlang-6.4.0.1 clang-1800.0.1)\n"
                "Target: arm64-apple-macosx27.0.0\n",
                "",
            )
        outputs = {
            ("xcodegen", "version"): "Version: 2.45.4\n",
            ("/usr/bin/xcodebuild", "-version"): (
                "Xcode 27.0\nBuild version 27A5218g\n"
            ),
        }
        key = tuple(command)
        if Path(command[0]).name == "xcodegen":
            key = ("xcodegen", *command[1:])
        if key not in outputs:
            return subprocess.CompletedProcess(command, 127, "", f"unexpected {key!r}")
        return subprocess.CompletedProcess(command, 0, outputs[key], "")


class ReleaseRepositoryFixture:
    def __init__(self, root: Path) -> None:
        self.root = root.resolve(strict=True)
        root = self.root
        self.project_yml = root / "MacScope" / "project.yml"
        self.output = (
            root
            / "Build/MacScope.app/Contents/Resources/MacScopeBuildProvenance.json"
        )
        self.native_decompiler_golden_result = (
            root
            / "Build/MacScope.app/Contents/XPCServices/"
            "NativeDecompilerXPCService.xpc/Contents/Resources/"
            "NativeDecompilerBridgeGolden.json"
        )
        self.xcodeproj = root / "MacScope" / "MacScope.xcodeproj"
        self.developer_dir = root / "FixtureDeveloper"
        self.swift_executable = (
            self.developer_dir
            / "Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc"
        )
        self.ghostty_source_dir = root / "FixtureDependencies/Ghostty"
        self.ghostty_surface_manifest = (
            root
            / "FixtureDependencies/GhosttySurface/macos/"
            ".macscope-ghostty-surface-manifest"
        )
        self.ghostty_surface_staged_root = root / "Build/GhosttySurfaceStaged"
        self.ghostty_surface_staged_descriptor = (
            self.ghostty_surface_staged_root / "STAGED_GHOSTTY_SURFACE.json"
        )
        self.sleigh_materialization_root = root / "FixtureDependencies/SLEIGH"
        self.machokit_materialization_root = root / "FixtureDependencies/MachOKit"
        self.analysis_worker_executable = (
            root
            / "Build/MacScope.app/Contents/XPCServices/"
            "AnalysisWorkerXPCService.xpc/Contents/MacOS/AnalysisWorkerXPCService"
        )
        self.ghostty_source_dir.mkdir(parents=True)
        self.ghostty_surface_manifest.parent.mkdir(parents=True)
        self.ghostty_surface_staged_root.mkdir(parents=True)
        self.sleigh_materialization_root.mkdir(parents=True)
        self.machokit_materialization_root.mkdir(parents=True)
        (self.machokit_materialization_root / "MATERIALIZATION.json").write_text(
            "{}\n",
            encoding="utf-8",
        )
        compiled_identity = load_machokit_compiled_identity_verifier()
        self.analysis_worker_executable.parent.mkdir(parents=True, exist_ok=True)
        self.analysis_worker_executable.write_bytes(
            b"fixture-mach-o\0" + compiled_identity.EXPECTED_MARKER + b"\0fixture-code"
        )
        self._embedded_package_hashes: dict[str, str] | None = None
        self._write_sources()
        self._write_ghostty_surface_fixture()
        self.embedded_package_hashes()
        self._initialize_repository()
        self.output.parent.mkdir(parents=True, exist_ok=True)

    def _write(self, relative_path: str, payload: bytes | str) -> None:
        path = self.root / relative_path
        path.parent.mkdir(parents=True, exist_ok=True)
        if isinstance(payload, str):
            path.write_text(payload, encoding="utf-8")
        else:
            path.write_bytes(payload)

    def _write_sources(self) -> None:
        self._write(
            "MacScope/project.yml",
            """\
name: MacScope
options:
  minimumXcodeGenVersion: 2.45.4
settings:
  base:
    SWIFT_VERSION: "6.0"
targets:
  MacScopeApp:
    sources:
      - path: App
      - path: Services
        excludes:
          - Phase2/Phase2ModelQualificationHarness.swift
          - Phase2/IgnoredExcluded.swift
          - Phase2/QualificationGate/**
      - path: Resources
        excludes:
          - Info.plist
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: org.macscope.app
  AnalysisWorkerXPCService:
    sources:
      - path: AnalysisWorker/Worker.swift
  AIAgentWorkerXPCService:
    sources:
      - path: AIAgentWorker/Worker.swift
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: org.macscope.app.AIAgentWorker
  ShellBrokerXPCService:
    sources:
      - path: ShellBrokerService/Broker.swift
  SourceExecutionRunner:
    type: tool
    platform: macOS
    sources:
      - path: SourceExecutionRunner/main.c
  ShellBrokerLaunchAgent:
    sources:
      - path: ShellBrokerService/Broker.swift
  NativeDecompilerXPCService:
    sources:
      - path: NativeDecompilerXPCService
        excludes:
          - Info.plist
  CoreTests:
    sources:
      - path: Services/Phase2/Phase2ModelQualificationHarness.swift
      - path: Services/Phase2/QualificationGate
      - path: Tests/CoreTests
        excludes:
          - GoldenFixtures/**
""",
        )
        self._write(
            "MacScope/DependencyRoots.xcconfig",
            '#include "SigningIdentity.xcconfig"\n'
            "MACSCOPE_GHOSTTY_SOURCE_DIR =\n"
            "MACSCOPE_SLEIGH_MATERIALIZATION_ROOT =\n"
            '#include? "DependencyRoots.local.xcconfig"\n',
        )
        self._write(
            "MacScope/SigningIdentity.xcconfig",
            "MACSCOPE_SIGNING_IDENTITY = fixture\nMACSCOPE_SIGNING_TEAM = FIXTURE\n",
        )
        self._write("MacScope/App/Main.swift", "struct Main {}\n")
        self._write("MacScope/Services/Kept.swift", "struct Kept {}\n")
        self._write("MacScope/Resources/Assets.xcassets/payload.bin", b"asset\x00bytes")
        self._write("MacScope/AnalysisWorker/Worker.swift", "struct AnalysisWorker {}\n")
        self._write("MacScope/AIAgentWorker/Worker.swift", "struct AIWorker {}\n")
        self._write(
            "MacScope/Services/Phase2/Phase2ModelQualificationHarness.swift",
            "struct QualificationHarness {}\n",
        )
        self._write(
            "MacScope/Services/Phase2/QualificationGate/Phase2QualificationGateBuildAuthority.swift",
            "struct GateBuildAuthority {}\n",
        )
        self._write(
            "MacScope/Services/Phase2/QualificationGate/Phase2QualificationGateComposer.swift",
            "struct GateComposer {}\n",
        )
        self._write(
            "MacScope/Tests/CoreTests/FixtureSmokeTests.swift",
            "struct FixtureSmokeTests {}\n",
        )
        self._write("MacScope/Resources/Info.plist", "<plist><dict/></plist>\n")
        self._write(
            "MacScope/AnalysisWorkerService/Info.plist",
            "<plist><dict/></plist>\n",
        )
        self._write(
            "MacScope/AIAgentWorkerService/Info.plist",
            "<plist><dict/></plist>\n",
        )
        self._write(
            "MacScope/ShellBrokerService/Info.plist",
            "<plist><dict/></plist>\n",
        )
        self._write(
            "MacScope/ShellBrokerService/LaunchAgentInfo.plist",
            "<plist><dict/></plist>\n",
        )
        self._write(
            "MacScope/ShellBrokerService/LaunchAgent.plist",
            "<plist><dict/></plist>\n",
        )
        self._write(
            "MacScope/ShellBrokerService/Broker.swift",
            "struct ShellBroker {}\n",
        )
        self._write("MacScope/SourceExecutionRunner/main.c", "int main(void){return 0;}\n")
        self._write("MacScope/SourceExecutionRunner/Info.plist", "<plist><dict/></plist>\n")
        self._write(
            "MacScope/NativeDecompilerXPCService/Info.plist",
            "<plist><dict/></plist>\n",
        )
        self._write(
            "MacScope/NativeDecompilerXPCService/ServiceMain.swift",
            "struct NativeDecompilerServiceMain {}\n",
        )
        self._write(
            "MacScope/NativeDecompilerXPCService/Bridge/NativeBridge.mm",
            "// fixture native bridge\n",
        )
        self._write(
            "Scripts/native-decompiler-xpc/build_native_bridge.sh",
            "#!/bin/sh\nexit 0\n",
        )
        self._write(
            "Scripts/native-decompiler-xpc/stage_verified_package.py",
            "# fixture package stage script\n",
        )
        self._write(
            "Scripts/native-decompiler-xpc/native_decompiler_source_identity.py",
            SOURCE_IDENTITY_HELPER.read_bytes(),
        )
        self._write(
            "Scripts/machokit_source_identity.py",
            MACHOKIT_SOURCE_IDENTITY_HELPER.read_bytes(),
        )
        self._write(
            "Scripts/verify_machokit_analysis_worker_identity.py",
            MACHOKIT_COMPILED_IDENTITY_VERIFIER.read_bytes(),
        )
        self._write(
            "Scripts/dependencies/materialize_machokit.py",
            MACHOKIT_MATERIALIZER.read_bytes(),
        )
        self._write(
            "Scripts/dependencies/stage_verified_ghostty_surface.py",
            "# fixture verified Ghostty surface stager\n",
        )
        self._write(
            "Scripts/native-decompiler-direct/verify_sleigh_package.py",
            "# fixture package verifier\n",
        )
        self._write(
            "Scripts/native-decompiler-direct/sleigh_package.py",
            "# fixture package model\n",
        )
        self._write(
            "Tools/NativeDecompilerBridge/CMakeLists.txt",
            "# fixture native bridge\n",
        )
        helper_specification = importlib.util.spec_from_file_location(
            "release_fixture_native_source_identity",
            SOURCE_IDENTITY_HELPER,
        )
        if helper_specification is None or helper_specification.loader is None:
            raise AssertionError("could not load native source identity fixture contract")
        helper_module = importlib.util.module_from_spec(helper_specification)
        previous_dont_write_bytecode = sys.dont_write_bytecode
        try:
            sys.dont_write_bytecode = True
            helper_specification.loader.exec_module(helper_module)
        finally:
            sys.dont_write_bytecode = previous_dont_write_bytecode
        # The wrapper profile also binds the dependency-cache modules (e589845e7).
        for relative_path in (*helper_module.WRAPPER_FIXED, *helper_module.GOLDEN_FIXED):
            candidate = self.root / relative_path
            if not candidate.exists():
                self._write(relative_path, f"fixture input: {relative_path}\n")
        self._write(
            "Scripts/native-decompiler-xpc/FixtureInputs.xcfilelist",
            "$(SRCROOT)/fixture-input\n",
        )
        self._write(
            "Scripts/native-decompiler-xpc/FixtureOutputs.xcfilelist",
            "$(DERIVED_FILE_DIR)/fixture-output\n",
        )
        self._write(
            "Scripts/generate_release_build_provenance.py",
            GENERATOR.read_bytes(),
        )
        self._write(
            "Scripts/source_export_provenance.py",
            SOURCE_EXPORT_TOOL.read_bytes(),
        )
        # The generator selects the Release publication admission helpers
        # (release_provenance_admission.SOURCE_INPUTS, fff93dcc9).
        for relative_path in RELEASE_ADMISSION_SOURCE_INPUTS:
            self._write(relative_path, (REPOSITORY_ROOT / relative_path).read_bytes())
        self._write("Scripts/check_local_signing_policy.py", "# fixture signing guard\n")
        self._write("Scripts/project_freshness.py", "# fixture freshness contract\n")
        self._write("Scripts/xcode_project_json.py", "# fixture parser\n")
        self._write("Scripts/generate_xcode_json_project.py", "# fixture generator\n")
        self._write(
            "MacScope/PARITY_CONTRACT.md",
            "# fixture capability contract\n",
        )
        fixture_manifest = {
            "schema_version": 1,
            "distribution_policy": {
                "status": "private-development-only",
                "public_distribution_approved": False,
                "decision_record": "docs/dependencies/LicenseDecision.md",
            },
            "components": [
                {
                    "id": "fixture-tool",
                    "name": "Fixture Tool",
                    "canonical_repository": "https://example.invalid/fixture/tool",
                    "approval": "tooling-oracle-approved",
                    "integration_mode": "developer-tool",
                    "license_expression": "MIT",
                    "pin": {"source_sha256": "0" * 64},
                    "tracked_paths": ["ThirdParty/FixtureTool"],
                    "materialization": {
                        "script": "Scripts/dependencies/materialize_fixture_tool.py",
                        "network_allowed": False,
                        "implicit_build_invocation": False,
                        "expected_untracked_root": None,
                    },
                    "license_paths": ["ThirdParty/FixtureTool/LICENSE.txt"],
                    "license_sha256": "0" * 64,
                    "notice_paths": ["THIRD_PARTY_NOTICES.md"],
                    "patches_path": "ThirdParty/FixtureTool/PATCHES.md",
                    "targets": ["fixture"],
                    "review": {
                        "date": "2026-07-20",
                        "status": "reviewed-private-development",
                        "public_distribution_blocked": True,
                        "reviewer": "fixture",
                    },
                    "notes": "fixture",
                }
            ],
        }
        self._write(
            "THIRD_PARTY_COMPONENTS.yml",
            json.dumps(fixture_manifest, indent=2) + "\n",
        )
        self._write(
            "THIRD_PARTY_NOTICES.md",
            "# Fixture notices\n<!-- component:fixture-tool -->\n",
        )
        self._write(
            "docs/dependencies/LicenseDecision.md",
            "# Fixture decision\nPublic distribution is unresolved.\n",
        )
        self._write(
            "Scripts/dependencies/third_party_components.schema.json",
            "{\"fixture\":true}\n",
        )
        self._write(
            "Scripts/dependencies/validate_offline_build_surface.py",
            "# fixture offline validator\n",
        )
        self._write(
            "Scripts/dependencies/validate_policy_consistency.py",
            "# fixture policy validator\n",
        )
        self._write(
            "Scripts/dependencies/validate_third_party_components.py",
            "# fixture inventory validator\n",
        )
        self._write(
            "Scripts/dependencies/materialize_fixture_tool.py",
            "# fixture materializer; intentionally offline\n",
        )
        self._write("ThirdParty/FixtureTool/LICENSE.txt", "Fixture MIT license\n")
        self._write("ThirdParty/FixtureTool/PATCHES.md", "# Patch ledger\nNo patches.\n")
        self._write("ThirdParty/FixtureTool/README.md", "# Fixture tool\n")
        self._write(
            "MacScope/MacScope.xcodeproj/project.xcproj",
            FIXTURE_PBX,
        )
        self._write(self.swift_executable.relative_to(self.root).as_posix(), "fixture swiftc\n")
        self._write(
            ".gitignore",
            "Build/\nMacScope/App/IgnoredGenerated.swift\n"
            "MacScope/Services/Phase2/IgnoredExcluded.swift\n"
            "MacScope/Services/Phase2/QualificationGate/IgnoredGateSupport.swift\n"
            "MacScope/MacScope.xcodeproj/\nFixtureDependencies/\n",
        )

    def _write_ghostty_surface_fixture(self) -> None:
        module = load_generator_module()
        staged = {
            "libghostty-internal.a": b"fixture-ghostty-surface-archive\n",
            "Headers/ghostty.h": b"fixture-ghostty-surface-header\n",
            "Headers/module.modulemap": b"fixture-ghostty-surface-module-map\n",
        }
        leaf_hashes: dict[str, str] = {}
        for relative, payload in staged.items():
            path = self.ghostty_surface_staged_root / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(payload)
            leaf_hashes[path.name] = hashlib.sha256(payload).hexdigest()
        manifest = {
            **module.EXPECTED_GHOSTTY_SURFACE_MANIFEST_FIELDS,
            "info_plist_sha256": hashlib.sha256(
                b"fixture-ghostty-surface-info-plist\n"
            ).hexdigest(),
            "archive_sha256": leaf_hashes["libghostty-internal.a"],
            "header_sha256": leaf_hashes["ghostty.h"],
            "module_map_sha256": leaf_hashes["module.modulemap"],
        }
        payload = "".join(
            f"{key}={manifest[key]}\n"
            for key in module.GHOSTTY_SURFACE_MANIFEST_KEYS
        )
        self.ghostty_surface_manifest.write_text(payload, encoding="utf-8")
        descriptor = {
            "leaves": [
                {
                    "role": role,
                    "relative_path": relative_path,
                    "sha256": manifest[manifest_field],
                }
                for role, relative_path, manifest_field in (
                    module.GHOSTTY_SURFACE_STAGED_LEAVES
                )
            ],
            "schema_version": 1,
            "source_manifest_sha256": hashlib.sha256(
                self.ghostty_surface_manifest.read_bytes()
            ).hexdigest(),
        }
        self.ghostty_surface_staged_descriptor.write_bytes(
            module.canonical_json(descriptor)
        )

    def _initialize_repository(self) -> None:
        run_git(self.root, "init", "-q")
        run_git(self.root, "config", "user.email", "fixture@example.invalid")
        run_git(self.root, "config", "user.name", "Fixture")
        run_git(self.root, "add", ".")
        run_git(self.root, "commit", "-qm", "fixture")

    def golden_result_payload(self) -> dict[str, object]:
        module = load_generator_module()
        wrapper_source_sha256, golden_source_sha256 = (
            module.native_decompiler_source_identities(self.root)
        )
        hashes = {
            key: hashlib.sha256(key.encode("utf-8")).hexdigest()
            for key in (
                "contractArchiveSHA256",
                "contractBuildIdentitySHA256",
                "decompilerArchiveSHA256",
                "materializationManifestSHA256",
                "materializationTreeSHA256",
                "objcMappingSHA256",
                "objcReplySHA256",
                "objcRequestSHA256",
                "packageBackedReplySHA256",
                "packageBackedRequestSHA256",
                "packageBackedSwiftReplySHA256",
                "sleighArchiveSHA256",
                "stageStampSHA256",
                "swiftReplySHA256",
            )
        }
        package_hashes = self.embedded_package_hashes()
        hashes.update(
            {
                "materializationManifestSHA256": package_hashes["manifest"],
                "materializationTreeSHA256": package_hashes["tree"],
                "decompilerArchiveSHA256": package_hashes["decompiler"],
                "sleighArchiveSHA256": package_hashes["sleigh"],
            }
        )
        return {
            "architecture": "arm64",
            "backendID": "ghidra-native-decompiler",
            **hashes,
            "deploymentTarget": "27.0",
            "engineGitRevision": "c0f584bf229fffba61b36431f3ce30c0c3e4e682",
            "engineVersion": "12.1.2",
            "goldenSourceSHA256": golden_source_sha256,
            "passed": True,
            "schemaVersion": 1,
            "sdkBuild": "26A5378i",
            "sdkName": "macosx27.0",
            "sdkVersion": "27.0",
            "swiftCompilerVersion": "6.4",
            "swiftTargetTriple": "arm64-apple-macosx27.0.0",
            "wrapperGitRevision": wrapper_source_sha256,
            "wrapperVersion": "dcp05c-v1",
            "xcodeBuild": "27A5218g",
            "xcodeVersion": "27.0",
        }

    def embedded_package_hashes(self) -> dict[str, str]:
        if self._embedded_package_hashes is not None:
            return self._embedded_package_hashes
        materialization_root = self.native_decompiler_golden_result.parent / "NativeDecompilerPackage"
        package_root = materialization_root / "package"
        libraries = package_root / "lib"
        libraries.mkdir(parents=True, exist_ok=True)
        decompiler = libraries / "libdecomp.a"
        sleigh = libraries / "libsla.a"
        decompiler.write_bytes(b"fixture-decompiler-archive\n")
        sleigh.write_bytes(b"fixture-sleigh-archive\n")
        note = package_root / "share/package-note.txt"
        note.parent.mkdir(parents=True)
        note.write_bytes(b"fixture-noncritical-package-file\n")
        for index, relative_path in enumerate(
            APPLE_SILICON_CRITICAL_FILE_RELATIVE_PATHS
        ):
            path = package_root / relative_path
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(f"fixture-apple-profile-{index}\n".encode())
        package_hashes = self.rewrite_embedded_package_identity()
        record_hashes = package_hashes["record_hashes"]
        manifest_bytes = package_hashes["manifest_bytes"]
        service_root = self.native_decompiler_golden_result.parents[2]
        info_path = service_root / "Contents/Info.plist"
        executable_path = service_root / "Contents/MacOS/NativeDecompilerXPCService"
        code_resources_path = service_root / "Contents/_CodeSignature/CodeResources"
        info_bytes = plistlib.dumps(
            {
                "CFBundleIdentifier": "org.macscope.app.NativeDecompiler",
                "CFBundleExecutable": "NativeDecompilerXPCService",
                "CFBundlePackageType": "XPC!",
            },
            fmt=plistlib.FMT_BINARY,
            sort_keys=True,
        )
        info_path.write_bytes(info_bytes)
        executable_path.parent.mkdir(parents=True, exist_ok=True)
        executable_bytes = b"fixture-native-decompiler-service\n"
        executable_path.write_bytes(executable_bytes)
        code_resources_path.parent.mkdir(parents=True, exist_ok=True)
        code_resources_bytes = b"fixture-sealed-code-resources\n"
        code_resources_path.write_bytes(code_resources_bytes)
        self._embedded_package_hashes = {
            "manifest": hashlib.sha256(manifest_bytes).hexdigest(),
            "tree": package_hashes["tree"],
            "decompiler": record_hashes["lib/libdecomp.a"],
            "sleigh": record_hashes["lib/libsla.a"],
            "service_info": hashlib.sha256(info_bytes).hexdigest(),
            "service_executable": hashlib.sha256(executable_bytes).hexdigest(),
            "service_code_resources": hashlib.sha256(code_resources_bytes).hexdigest(),
        }
        return self._embedded_package_hashes

    def rewrite_embedded_package_identity(
        self,
        *,
        omitted_critical_paths: frozenset[str] = frozenset(),
        critical_override: dict[str, str] | None = None,
        schema_version: int = 1,
    ) -> dict[str, object]:
        materialization_root = (
            self.native_decompiler_golden_result.parent / "NativeDecompilerPackage"
        )
        package_root = materialization_root / "package"
        records: list[tuple[str, int, str]] = []
        for path in sorted(
            (item for item in package_root.rglob("*") if item.is_file()),
            key=lambda item: os.fsencode(item.relative_to(package_root).as_posix()),
        ):
            relative = path.relative_to(package_root).as_posix()
            payload = path.read_bytes()
            records.append((relative, len(payload), hashlib.sha256(payload).hexdigest()))
        tree = hashlib.sha256()
        for relative, size, digest in records:
            tree.update(relative.encode("utf-8"))
            tree.update(b"\0")
            tree.update(str(size).encode("ascii"))
            tree.update(b"\0")
            tree.update(digest.encode("ascii"))
            tree.update(b"\0")
        record_hashes = {relative: digest for relative, _size, digest in records}
        critical_hashes = {
            relative: digest
            for relative, digest in record_hashes.items()
            if relative not in omitted_critical_paths
        }
        if critical_override is not None:
            critical_hashes = critical_override
        identity_field = (
            {
                "artifact": {
                    "filename": "macOS-sleigh-12.1.2-1.arm64.tar.gz",
                    "platform": "macos-arm64",
                    "sha256": "e1391c811de7b2d79c9e8a1f6f74cd9ade23baf55deebd75c626a3152e5e451a",
                    "url": (
                        "https://github.com/lifting-bits/sleigh/releases/download/v12.1.2/"
                        "macOS-sleigh-12.1.2-1.arm64.tar.gz"
                    ),
                }
            }
            if schema_version == 1
            else {"sourceBuild": {"fixtureStrictVerifierSeam": True}}
        )
        manifest = {
            **identity_field,
            "componentId": (
                "sleigh-native-dcp03b4"
                if schema_version == 1
                else "sleigh-native-source-dcp03b4"
            ),
            "ghidraGitRevision": "c0f584bf229fffba61b36431f3ce30c0c3e4e682",
            "ghidraVersion": "12.1.2",
            "package": {
                "cmakeConfigRelativePath": "lib/cmake/sleigh/sleighConfig.cmake",
                "criticalFileSha256": critical_hashes,
                "decompilerLibraryRelativePath": "lib/libdecomp.a",
                "fileCount": len(records),
                "processorSpecRelativeRoot": (
                    "share/sleigh/specfiles/Ghidra/Processors/AARCH64/data/languages"
                ),
                "relativeRoot": "package",
                "sleighLibraryRelativePath": "lib/libsla.a",
                "totalBytes": sum(size for _relative, size, _digest in records),
                "treeSha256": tree.hexdigest(),
            },
            "schemaVersion": schema_version,
            "sleighGitRevision": "bfd38a983b4aa53dd386365e1df5ed5499b7e2fb",
            "sleighVersion": "12.1.2",
        }
        manifest_bytes = (
            json.dumps(manifest, sort_keys=True, separators=(",", ":")) + "\n"
        ).encode()
        (materialization_root / "MATERIALIZATION.json").write_bytes(manifest_bytes)
        external_package = self.sleigh_materialization_root / "package"
        if external_package.exists():
            shutil.rmtree(external_package)
        shutil.copytree(package_root, external_package)
        (self.sleigh_materialization_root / "MATERIALIZATION.json").write_bytes(
            manifest_bytes
        )
        package_hashes: dict[str, object] = {
            "manifest": hashlib.sha256(manifest_bytes).hexdigest(),
            "tree": tree.hexdigest(),
            "decompiler": record_hashes["lib/libdecomp.a"],
            "sleigh": record_hashes["lib/libsla.a"],
            "record_hashes": record_hashes,
            "manifest_bytes": manifest_bytes,
        }
        if self._embedded_package_hashes is not None:
            self._embedded_package_hashes.update(
                {
                    key: package_hashes[key]
                    for key in ("manifest", "tree", "decompiler", "sleigh")
                }
            )
        return package_hashes

    def write_golden_result(
        self,
        payload: dict[str, object] | None = None,
        *,
        canonical: bool = True,
    ) -> bytes:
        value = payload if payload is not None else self.golden_result_payload()
        self.native_decompiler_golden_result.parent.mkdir(parents=True, exist_ok=True)
        if canonical:
            encoded = (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode()
        else:
            encoded = (json.dumps(value, indent=2, sort_keys=True) + "\n").encode()
        self.native_decompiler_golden_result.write_bytes(encoded)
        return encoded

    def arguments(self, module, configuration: str = "Release"):
        golden_result = self.native_decompiler_golden_result
        self.write_golden_result()
        return module.ProvenanceArguments(
            repository_root=self.root,
            project_yml=self.project_yml,
            project_file_path=self.xcodeproj,
            configuration=configuration,
            architectures="arm64",
            deployment_target="27.0",
            sdk_name="macosx27.0",
            sdk_version="27.0",
            sdk_build="26A5378i",
            developer_dir=self.developer_dir,
            swift_executable=self.swift_executable,
            output=self.output,
            native_decompiler_golden_result=golden_result,
            ghostty_source_dir=self.ghostty_source_dir,
            ghostty_surface_manifest=self.ghostty_surface_manifest,
            ghostty_surface_staged_root=self.ghostty_surface_staged_root,
            sleigh_materialization_root=self.sleigh_materialization_root,
            sleigh_materialization_verifier=lambda root: json.loads(
                (root / "MATERIALIZATION.json").read_text(encoding="utf-8")
            ),
            machokit_materialization_root=self.machokit_materialization_root,
            machokit_identity_verifier=(
                lambda _root: dict(module.MACHOKIT_EXPECTED_IDENTITY)
            ),
            analysis_worker_executable=self.analysis_worker_executable,
            swift_active_compilation_conditions="MACSCOPE_FULL_GHOSTTY_SURFACE",
        )


class ReleaseBuildProvenanceTests(unittest.TestCase):
    def test_debug_and_release_builds_emit_provenance_and_unknown_configuration_fails(self) -> None:
        scripts = re.findall(r"        script: \|\n((?:          .*\n)+)",
            (REPOSITORY_ROOT / "MacScope/project.yml").read_text(encoding="utf-8"))
        body = next(value for value in scripts if "generate_release_build_provenance.py" in value)
        script = "\n".join(line[10:] for line in body.splitlines())
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            (root / "Scripts").mkdir()
            (root / "MacScope").mkdir()
            marker = root / "configuration.txt"
            (root / "Scripts/generate_release_build_provenance.py").write_text(
                "import os, pathlib, sys\n"
                "pathlib.Path(os.environ['PROVENANCE_DISPATCH_MARKER']).write_text("
                "sys.argv[sys.argv.index('--configuration') + 1])\n", encoding="utf-8")
            for configuration in ("Debug", "Release", "Unsupported"):
                with self.subTest(configuration=configuration):
                    marker.unlink(missing_ok=True)
                    environment = dict(os.environ, CONFIGURATION=configuration,
                        SRCROOT=str(root / "MacScope"), PROVENANCE_DISPATCH_MARKER=str(marker))
                    completed = subprocess.run(["/bin/sh", "-c", script], env=environment,
                        capture_output=True, text=True, check=False)
                    if configuration == "Unsupported":
                        self.assertNotEqual(completed.returncode, 0)
                        self.assertFalse(marker.exists(), "Unknown profiles must not emit a receipt")
                    else:
                        self.assertEqual(completed.returncode, 0, completed.stderr)
                        self.assertTrue(marker.is_file(), "Both profiles must invoke the truthful producer")
                        self.assertEqual(marker.read_text(), configuration)

    def test_project_coretests_copy_preserves_debug_provenance_bytes(self) -> None:
        scripts = re.findall(r"        script: \|\n((?:          .*\n)+)",
            (REPOSITORY_ROOT / "MacScope/project.yml").read_text(encoding="utf-8"))
        body = next(value for value in scripts if 'SOURCE="$BUILT_PRODUCTS_DIR/MacScope.app/' in value)
        script = "\n".join(line[10:] for line in body.splitlines())
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            resources = root / "products/MacScope.app/Contents/Resources"
            resources.mkdir(parents=True)
            payload = b'{"configuration":"Debug","qualification_eligible":false,"repository_clean":false}\n'
            (resources / "MacScopeBuildProvenance.json").write_bytes(payload)
            settings = {"BUILT_PRODUCTS_DIR": str(root / "products"),
                "TARGET_BUILD_DIR": str(root / "tests"), "UNLOCALIZED_RESOURCES_FOLDER_PATH": "Resources"}
            for name, value in settings.items():
                script = script.replace(f"$({name})", value)
            completed = subprocess.run(["/bin/sh", "-c", script],
                env=dict(os.environ, CONFIGURATION="Debug", **settings),
                capture_output=True, text=True, check=False)
            self.assertEqual(completed.returncode, 0, completed.stderr)
            destination = root / "tests/Resources/MacScopeBuildProvenance.json"
            self.assertTrue(destination.is_file(), "Debug CoreTests must receive the actual app receipt")
            self.assertEqual(destination.read_bytes(), payload)
            unsupported = subprocess.run(["/bin/sh", "-c", script],
                env=dict(os.environ, CONFIGURATION="Unsupported", **settings),
                capture_output=True, text=True, check=False)
            self.assertNotEqual(unsupported.returncode, 0)
            self.assertEqual(destination.read_bytes(), payload)

    def test_direct_git_lfs_selected_inputs_bind_materialized_digest_and_size(self) -> None:
        module = load_generator_module()
        relative = "ThirdParty/SleighNative/package/lib/libdecomp.a"
        payload = b"materialized native archive fixture\n"
        pointer = ("version https://git-lfs.github.com/spec/v1\n"
                   f"oid sha256:{hashlib.sha256(payload).hexdigest()}\n"
                   f"size {len(payload)}\n").encode()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            run_git(root, "init", "-q")
            run_git(root, "config", "user.name", "Fixture")
            run_git(root, "config", "user.email", "fixture@example.invalid")
            path = root / relative
            path.parent.mkdir(parents=True)
            path.write_bytes(pointer)
            run_git(root, "add", ".")
            run_git(root, "commit", "-qm", "canonical pointer")
            path.write_bytes(payload)
            self.assertEqual(module.selected_input_hashes(root, {relative}),
                             {relative: hashlib.sha256(payload).digest()})
            for invalid in (pointer, payload[:-1], b"x" * len(payload)):
                path.write_bytes(invalid)
                with self.subTest(payload=invalid), self.assertRaises(module.ProvenanceError):
                    module.selected_input_hashes(root, {relative})
            path.write_bytes(payload)
            self.assertEqual(module.selected_input_hashes(root, {relative}),
                             {relative: hashlib.sha256(payload).digest()})

    def _add_lumen_submodule(self, fixture: ReleaseRepositoryFixture) -> Path:
        package = fixture.root / "ThirdParty/Lumen"
        package.mkdir(parents=True)
        run_git(package, "init", "-q")
        run_git(package, "config", "user.name", "Fixture")
        run_git(package, "config", "user.email", "fixture@example.invalid")
        run_git(package, "remote", "add", "origin", "https://github.com/jdotc1/Lumen.git")
        (package / "Package.swift").write_text("// swift-tools-version:6.1\n", encoding="utf-8")
        (package / "Sources").mkdir()
        (package / "Sources/Color.swift").write_text("let color = 1\n", encoding="utf-8")
        (package / ".gitignore").write_text(".build/\n", encoding="utf-8")
        run_git(package, "add", ".")
        run_git(package, "commit", "-qm", "pinned package")
        fixture._write(".gitmodules", '[submodule "ThirdParty/Lumen"]\n'
                       '\tpath = ThirdParty/Lumen\n\turl = https://github.com/jdotc1/Lumen.git\n')
        spec = fixture.project_yml.read_text(encoding="utf-8")
        fixture.project_yml.write_text(
            "packages:\n  Lumen:\n    path: ../ThirdParty/Lumen\n" + spec,
            encoding="utf-8",
        )
        run_git(fixture.root, "add", ".gitmodules", "MacScope/project.yml")
        run_git(fixture.root, "update-index", "--add", "--cacheinfo",
                f"160000,{run_git(package, 'rev-parse', 'HEAD')},ThirdParty/Lumen")
        run_git(fixture.root, "commit", "-qm", "adopt pinned package")
        return package

    def test_release_hashes_pinned_submodule_files_and_rejects_wrong_checkout(self) -> None:
        module = load_generator_module()
        with tempfile.TemporaryDirectory() as temporary_directory:
            fixture = ReleaseRepositoryFixture(Path(temporary_directory))
            package = self._add_lumen_submodule(fixture)
            relative = "ThirdParty/Lumen/Sources/Color.swift"
            hashes = module.selected_input_hashes(fixture.root, {relative})
            self.assertEqual(hashes[relative], hashlib.sha256(b"let color = 1\n").digest())
            (package / "Sources/Color.swift").write_text("let color = 2\n", encoding="utf-8")
            run_git(package, "add", ".")
            run_git(package, "commit", "-qm", "unapproved package change")
            with self.assertRaises(module.ProvenanceError):
                module.selected_input_hashes(fixture.root, {relative})

    def test_release_selects_lumen_package_closure_without_ignored_build_debris(self) -> None:
        module = load_generator_module()
        with tempfile.TemporaryDirectory() as temporary_directory:
            fixture = ReleaseRepositoryFixture(Path(temporary_directory))
            package = self._add_lumen_submodule(fixture)
            (package / ".build").mkdir()
            (package / ".build/cache.swift").write_text("ignored debris", encoding="utf-8")
            selected = module.selected_source_paths(
                fixture.root, fixture.project_yml,
                fixture.project_yml.read_text(encoding="utf-8"),
            )
            self.assertIn("ThirdParty/Lumen/Package.swift", selected)
            self.assertIn("ThirdParty/Lumen/Sources/Color.swift", selected)
            self.assertIn(".gitmodules", selected)
            self.assertNotIn("ThirdParty/Lumen/.build/cache.swift", selected)
            self.assertFalse(any("/.git/" in path for path in selected))

    def test_release_seals_first_party_policy_authority_when_declared(self) -> None:
        module = load_generator_module()
        with tempfile.TemporaryDirectory() as temporary_directory:
            fixture = ReleaseRepositoryFixture(Path(temporary_directory))
            self._add_lumen_submodule(fixture)
            authorities = {
                "FIRST_PARTY_COMPONENTS.json": "{}\n",
                "Scripts/dependencies/first_party_components.py": "# policy verifier\n",
                "Scripts/dependencies/materialize_lumen_submodule.py": "# offline preparation\n",
            }
            for relative, content in authorities.items():
                fixture._write(relative, content)
            run_git(fixture.root, "add", *authorities)
            run_git(fixture.root, "commit", "-qm", "declare first-party authority")
            selected = module.selected_source_paths(
                fixture.root, fixture.project_yml,
                fixture.project_yml.read_text(encoding="utf-8"),
            )
            self.assertTrue(set(authorities).issubset(selected))
            hashes = module.selected_input_hashes(fixture.root, set(authorities))
            self.assertEqual(set(hashes), set(authorities))
            fixture._write("FIRST_PARTY_COMPONENTS.json", '{"tampered":true}\n')
            with self.assertRaises(module.ProvenanceError):
                module.selected_input_hashes(fixture.root, set(authorities))

    def test_release_regeneration_exposes_the_declared_lumen_sibling(self) -> None:
        module = load_generator_module()
        with tempfile.TemporaryDirectory() as temporary_directory:
            fixture = ReleaseRepositoryFixture(Path(temporary_directory))
            self._add_lumen_submodule(fixture)
            runner = FixtureToolRunner()
            inspected = []

            def inspect_package(command, cwd):
                if Path(command[0]).name == "xcodegen" and command[1] == "generate":
                    package = cwd.parent / "ThirdParty/Lumen/Package.swift"
                    self.assertTrue(package.is_file(), "Release regeneration lost local package")
                    inspected.append(package.read_bytes())
                return runner(command, cwd)

            module.require_fresh_generated_project(
                fixture.arguments(module), fixture.root, tool_runner=inspect_package,
            )
            self.assertEqual(inspected, [b"// swift-tools-version:6.1\n"])

    def test_release_selects_and_regenerates_governed_rea_siblings(self) -> None:
        module = load_generator_module()
        with tempfile.TemporaryDirectory() as directory:
            fixture = ReleaseRepositoryFixture(Path(directory))
            inputs = {
                "ThirdParty/REA/generated/REAEmbeddedIdentity.swift": "let identity = 1\n",
                "ThirdParty/REA/generated/MacScopeREAKernel.js": "kernel();\n",
                "ThirdParty/REA/licenses/REA/LICENSE": "fixture license\n",
            }
            for relative, content in inputs.items():
                fixture._write(relative, content)
            spec = fixture.project_yml.read_text()
            spec = spec.replace("      - path: App\n", "      - path: App\n" + "".join(
                f"      - path: {path}\n" for path in sorted(module.REA_REPOSITORY_SOURCE_PATHS)
            ), 1)
            fixture.project_yml.write_text(spec)
            run_git(fixture.root, "add", "MacScope/project.yml", "ThirdParty/REA")
            run_git(fixture.root, "commit", "-qm", "declare REA fixtures")
            selected = module.selected_source_paths(fixture.root, fixture.project_yml, spec)
            self.assertTrue(set(inputs).issubset(selected))
            self.assertFalse(any(".." in Path(path).parts for path in selected))
            hashes = module.selected_input_hashes(fixture.root, set(inputs))
            for relative, content in inputs.items():
                self.assertEqual(hashes[relative], hashlib.sha256(content.encode()).digest())
            runner = FixtureToolRunner()
            inspected = []
            def inspect_rea(command, cwd):
                if Path(command[0]).name == "xcodegen" and command[1] == "generate":
                    for relative, content in inputs.items():
                        self.assertEqual((cwd.parent / relative).read_text(), content)
                    inspected.append(True)
                return runner(command, cwd)
            module.require_fresh_generated_project(
                fixture.arguments(module), fixture.root, tool_runner=inspect_rea,
            )
            self.assertEqual(inspected, [True])
            for invalid in ("../Other", "../ThirdParty/REA/../Other", "/tmp/REA"):
                with self.subTest(path=invalid), self.assertRaises(module.ProvenanceError):
                    module.selected_source_paths(fixture.root, fixture.project_yml,
                        spec.replace("../ThirdParty/REA/generated/REAEmbeddedIdentity.swift", invalid))

    def test_source_export_authority_ignores_timestamp_valid_cached_bytecode(self) -> None:
        module = load_generator_module()
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary = Path(temporary_directory)
            fake_generator = temporary / GENERATOR.name
            fake_generator.write_text("# fixture generator path\n", encoding="utf-8")
            helper = temporary / SOURCE_EXPORT_TOOL.name
            marker = temporary / "malicious-bytecode-executed"
            trusted_source = (
                "def load_verified_export(root, require_closed_tree=False):\n"
                "    return ({'trusted': True}, {'trusted-record': {}})\n"
            )
            malicious_source = (
                "from pathlib import Path\n"
                f"Path({str(marker)!r}).write_text('executed', encoding='utf-8')\n"
                "def load_verified_export(root, require_closed_tree=False):\n"
                "    return ({'trusted': False}, {'malicious-record': {}})\n"
            )
            source_size = max(len(trusted_source), len(malicious_source)) + 128

            def padded(source: str) -> str:
                return source + "#" + ("x" * (source_size - len(source) - 2)) + "\n"

            trusted_source = padded(trusted_source)
            malicious_source = padded(malicious_source)
            self.assertEqual(len(trusted_source), len(malicious_source))
            timestamp = 1_700_000_000
            helper.write_text(malicious_source, encoding="utf-8")
            os.utime(helper, (timestamp, timestamp))
            py_compile.compile(
                str(helper),
                doraise=True,
                invalidation_mode=py_compile.PycInvalidationMode.TIMESTAMP,
            )
            helper.write_text(trusted_source, encoding="utf-8")
            os.utime(helper, (timestamp, timestamp))

            cached_specification = importlib.util.spec_from_file_location(
                "cached_source_export_fixture",
                helper,
            )
            self.assertIsNotNone(cached_specification)
            self.assertIsNotNone(cached_specification.loader)
            cached_module = importlib.util.module_from_spec(cached_specification)
            cached_specification.loader.exec_module(cached_module)
            cached_provenance, _cached_records = cached_module.load_verified_export(
                temporary,
                require_closed_tree=False,
            )
            self.assertEqual(cached_provenance, {"trusted": False})
            self.assertTrue(marker.is_file())
            marker.unlink()

            with mock.patch.object(module, "__file__", str(fake_generator)):
                provenance, records = module._load_source_export_authority(temporary)

            self.assertEqual(provenance, {"trusted": True})
            self.assertEqual(records, {"trusted-record": {}})
            self.assertFalse(marker.exists())

    def test_release_seal_covers_dependency_and_signing_xcconfigs(self) -> None:
        module = load_generator_module()
        with tempfile.TemporaryDirectory() as temporary_directory:
            fixture = ReleaseRepositoryFixture(Path(temporary_directory))
            selected = module.selected_source_paths(
                fixture.root,
                fixture.project_yml,
                fixture.project_yml.read_text(encoding="utf-8"),
            )
            self.assertIn("MacScope/DependencyRoots.xcconfig", selected)
            self.assertIn("MacScope/SigningIdentity.xcconfig", selected)

    def test_release_seal_covers_shell_broker_products_and_surface_stager(self) -> None:
        module = load_generator_module()
        with tempfile.TemporaryDirectory() as temporary_directory:
            fixture = ReleaseRepositoryFixture(Path(temporary_directory))
            selected = module.selected_source_paths(
                fixture.root,
                fixture.project_yml,
                fixture.project_yml.read_text(encoding="utf-8"),
            )
            self.assertTrue(
                {
                    "MacScope/ShellBrokerService/Broker.swift",
                    "MacScope/ShellBrokerService/Info.plist",
                    "MacScope/ShellBrokerService/LaunchAgentInfo.plist",
                    "MacScope/ShellBrokerService/LaunchAgent.plist",
                    "Scripts/dependencies/stage_verified_ghostty_surface.py",
                }.issubset(selected)
            )

    def test_release_rejects_missing_relative_or_nondirectory_dependency_roots(self) -> None:
        module = load_generator_module()
        with tempfile.TemporaryDirectory() as temporary_directory:
            fixture = ReleaseRepositoryFixture(Path(temporary_directory))
            arguments = fixture.arguments(module)
            mutations = {
                "missing": fixture.root / "missing-ghostty",
                "relative": Path("relative-ghostty"),
                "file": fixture.project_yml,
            }
            for name, root in mutations.items():
                with self.subTest(name=name):
                    arguments.ghostty_source_dir = root
                    with self.assertRaisesRegex(
                        module.ProvenanceError,
                        "MACSCOPE_GHOSTTY_SOURCE_DIR",
                    ):
                        module.validate_arguments(arguments)
            arguments.ghostty_source_dir = fixture.ghostty_source_dir

            for name, root in {
                "missing": fixture.root / "missing-machokit",
                "relative": Path("relative-machokit"),
                "file": fixture.project_yml,
            }.items():
                with self.subTest(machokit=name):
                    arguments.machokit_materialization_root = root
                    with self.assertRaisesRegex(
                        module.ProvenanceError,
                        "MACSCOPE_MACHOKIT_MATERIALIZATION_ROOT",
                    ):
                        module.validate_arguments(arguments)
            arguments.machokit_materialization_root = fixture.machokit_materialization_root

            arguments.analysis_worker_executable = None
            with self.assertRaisesRegex(
                module.ProvenanceError,
                "AnalysisWorkerXPCService executable",
            ):
                module.validate_arguments(arguments)
            arguments.analysis_worker_executable = Path("relative-worker")
            with self.assertRaisesRegex(
                module.ProvenanceError,
                "AnalysisWorkerXPCService executable",
            ):
                module.validate_arguments(arguments)
            arguments.analysis_worker_executable = fixture.analysis_worker_executable

    def test_machokit_release_evidence_requires_the_reviewed_direct_source_identity(self) -> None:
        module = load_generator_module()
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory) / "MachOKit"
            root.mkdir()
            (root / "MATERIALIZATION.json").write_text("{}\n", encoding="utf-8")

            evidence = module.machokit_materialization_evidence(
                REPOSITORY_ROOT,
                root,
                identity_verifier=lambda _root: dict(module.MACHOKIT_EXPECTED_IDENTITY),
            )
            self.assertEqual(evidence["machokit_version"], "0.52.2")
            self.assertEqual(
                evidence["machokit_materialization_tree_sha256"],
                "e6796548485d32a183c3e1641989d637f5f6344c9e5af5a9cfbb83f549007950",
            )

            drifted = dict(module.MACHOKIT_EXPECTED_IDENTITY)
            drifted["revision"] = "0" * 40
            with self.assertRaisesRegex(
                module.ProvenanceError,
                "differs from the reviewed contract",
            ):
                module.machokit_materialization_evidence(
                    REPOSITORY_ROOT,
                    root,
                    identity_verifier=lambda _root: drifted,
                )

    def test_release_binds_the_verified_analysis_worker_machokit_identity(self) -> None:
        module = load_generator_module()
        compiled_identity = load_machokit_compiled_identity_verifier()
        with tempfile.TemporaryDirectory() as temporary_directory:
            fixture = ReleaseRepositoryFixture(Path(temporary_directory))
            executable = fixture.analysis_worker_executable
            original = executable.read_bytes()

            evidence = module.machokit_analysis_worker_evidence(
                fixture.root,
                executable,
            )
            self.assertEqual(
                evidence["machokit_analysis_worker_compiled_identity"],
                {
                    "schema": "macscope-machokit-compiled-identity-v1",
                    "revision": module.MACHOKIT_EXPECTED_IDENTITY["revision"],
                    "governed_source_identity": module.MACHOKIT_EXPECTED_IDENTITY[
                        "governed_source_identity"
                    ],
                },
            )
            self.assertEqual(
                evidence["machokit_analysis_worker_executable_sha256"],
                hashlib.sha256(original).hexdigest(),
            )
            self.assertEqual(
                evidence["machokit_analysis_worker_executable_size"], len(original)
            )

            mutations = {
                "missing": b"fixture-without-marker",
                "duplicate": original + b"\0" + compiled_identity.EXPECTED_MARKER,
                "drifted": original.replace(
                    compiled_identity.EXPECTED_MARKER,
                    compiled_identity.MARKER_PREFIX
                    + ("0" * 40).encode("ascii")
                    + b":"
                    + compiled_identity.GOVERNED_SOURCE_IDENTITY.encode("ascii"),
                ),
            }
            for name, payload in mutations.items():
                with self.subTest(name=name):
                    executable.write_bytes(payload)
                    with self.assertRaisesRegex(
                        module.ProvenanceError,
                        "compiled identity is invalid",
                    ):
                        module.machokit_analysis_worker_evidence(
                            fixture.root,
                            executable,
                        )

            executable.write_bytes(original + b"\0different-worker-code")
            changed = module.machokit_analysis_worker_evidence(
                fixture.root,
                executable,
            )
            self.assertNotEqual(
                changed["machokit_analysis_worker_executable_sha256"],
                evidence["machokit_analysis_worker_executable_sha256"],
            )

            executable.write_bytes(original)
            real_sha256_file = module.sha256_file

            def mutate_after_hash(path: Path):
                result = real_sha256_file(path)
                path.write_bytes(path.read_bytes() + b"\0raced")
                return result

            with mock.patch.object(
                module,
                "sha256_file",
                side_effect=mutate_after_hash,
            ):
                with self.assertRaisesRegex(
                    module.ProvenanceError,
                    "differs from the reviewed artifact contract",
                ):
                    module.machokit_analysis_worker_evidence(
                        fixture.root,
                        executable,
                    )

    def test_release_accepts_verified_gitless_source_export_without_changing_wire_shape(self) -> None:
        module = load_generator_module()
        runner = FixtureToolRunner()
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary = Path(temporary_directory).resolve()
            fixture_root = temporary / "fixture"
            fixture_root.mkdir()
            fixture = ReleaseRepositoryFixture(fixture_root)
            live_arguments = fixture.arguments(module)
            head = run_git(fixture.root, "rev-parse", "HEAD")
            run_git(
                fixture.root,
                "remote",
                "add",
                "origin",
                "https://github.com/example/MacScope.git",
            )
            run_git(
                fixture.root,
                "update-ref",
                "refs/remotes/origin/main",
                head,
            )
            exported = temporary / "exported"
            export = subprocess.run(
                [
                    "/usr/bin/python3",
                    str(SOURCE_EXPORT_TOOL),
                    "create",
                    "--repository-root",
                    str(fixture.root),
                    "--destination",
                    str(exported),
                    "--integration-ref",
                    "refs/remotes/origin/main",
                ],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(export.returncode, 0, export.stderr)
            shutil.copytree(fixture.root / "Build", exported / "Build")
            exported_project = exported / "MacScope/MacScope.xcodeproj"
            exported_project.mkdir(parents=True)
            (exported_project / "project.xcproj").write_bytes(FIXTURE_PBX)
            generated_cache = exported / "MacScope/App/__pycache__/Generated.pyc"
            generated_cache.parent.mkdir(parents=True, exist_ok=True)
            generated_cache.write_bytes(b"generated after export\n")

            arguments = module.ProvenanceArguments(
                repository_root=exported,
                project_yml=exported / "MacScope/project.yml",
                project_file_path=exported_project,
                configuration="Release",
                architectures=live_arguments.architectures,
                deployment_target=live_arguments.deployment_target,
                sdk_name=live_arguments.sdk_name,
                sdk_version=live_arguments.sdk_version,
                sdk_build=live_arguments.sdk_build,
                developer_dir=exported / live_arguments.developer_dir.relative_to(fixture.root),
                swift_executable=exported / live_arguments.swift_executable.relative_to(fixture.root),
                output=exported / live_arguments.output.relative_to(fixture.root),
                native_decompiler_golden_result=(
                    exported
                    / live_arguments.native_decompiler_golden_result.relative_to(fixture.root)
                ),
                ghostty_source_dir=live_arguments.ghostty_source_dir,
                ghostty_surface_manifest=live_arguments.ghostty_surface_manifest,
                ghostty_surface_staged_root=(
                    exported
                    / live_arguments.ghostty_surface_staged_root.relative_to(fixture.root)
                ),
                sleigh_materialization_root=live_arguments.sleigh_materialization_root,
                sleigh_materialization_verifier=(
                    live_arguments.sleigh_materialization_verifier
                ),
                machokit_materialization_root=(
                    live_arguments.machokit_materialization_root
                ),
                machokit_identity_verifier=live_arguments.machokit_identity_verifier,
                analysis_worker_executable=(
                    exported
                    / live_arguments.analysis_worker_executable.relative_to(fixture.root)
                ),
                swift_active_compilation_conditions=(
                    live_arguments.swift_active_compilation_conditions
                ),
            )

            payload = module.generate(arguments, tool_runner=runner)
            live_payload = module.generate(live_arguments, tool_runner=FixtureToolRunner())
            self.assertEqual(set(payload), set(live_payload))
            self.assertEqual(payload["schema_version"], 1)
            self.assertEqual(payload["git_head_commit"], live_payload["git_head_commit"])
            self.assertEqual(payload["git_head_tree"], live_payload["git_head_tree"])
            self.assertEqual(
                payload["selected_build_inputs_sha256"],
                live_payload["selected_build_inputs_sha256"],
            )

            arguments.configuration = "Debug"
            arguments.debug_source_identity = "source-qualified"
            debug_payload = module.generate(arguments, tool_runner=FixtureToolRunner())
            self.assertFalse(debug_payload["qualification_eligible"])
            self.assertFalse(debug_payload["repository_clean"])
            for key in ("git_head_commit", "git_head_tree", "selected_build_inputs_sha256"):
                self.assertEqual(debug_payload[key], live_payload[key], key)
            arguments.configuration = "Release"

            injected = exported / "MacScope/App/Injected.swift"
            injected.write_text("let injected = true\n", encoding="utf-8")
            with self.assertRaisesRegex(
                module.ProvenanceError,
                "absent from or differs from the sealed source export",
            ):
                module.generate(arguments, tool_runner=FixtureToolRunner())

            injected.unlink()
            candidate_helper = exported / "Scripts/source_export_provenance.py"
            candidate_helper.write_text(
                "#!/usr/bin/env python3\nraise SystemExit(0)\n",
                encoding="utf-8",
            )
            candidate_helper.chmod(0o755)
            with self.assertRaisesRegex(
                module.ProvenanceError,
                "sealed source export is invalid",
            ):
                module.generate(arguments, tool_runner=FixtureToolRunner())

    def test_release_rejects_native_decompiler_live_test_compilation_condition(self) -> None:
        module = load_generator_module()
        with tempfile.TemporaryDirectory() as temporary_directory:
            fixture = ReleaseRepositoryFixture(Path(temporary_directory))
            arguments = fixture.arguments(module)
            arguments.native_decompiler_live_test_condition = (
                "NATIVE_DECOMPILER_SIGNED_LIVE_TESTS"
            )

            with self.assertRaisesRegex(
                module.ProvenanceError,
                "empty native decompiler live-test condition",
            ):
                module.generate(arguments, tool_runner=FixtureToolRunner())

            arguments.native_decompiler_live_test_condition = ""
            arguments.swift_active_compilation_conditions = (
                "MACSCOPE_NATIVE_DECOMPILER_LIVE_XPC_TESTING"
            )
            with self.assertRaisesRegex(
                module.ProvenanceError,
                "live-test Swift condition",
            ):
                module.generate(arguments, tool_runner=FixtureToolRunner())

            arguments.swift_active_compilation_conditions = ""
            arguments.other_swift_flags = (
                "-DMACSCOPE_NATIVE_DECOMPILER_LIVE_XPC_TESTING"
            )
            with self.assertRaisesRegex(
                module.ProvenanceError,
                "live-test Swift flags",
            ):
                module.generate(arguments, tool_runner=FixtureToolRunner())

    def test_release_requires_strict_ghostty_surface_cli_and_staged_identity(self) -> None:
        module = load_generator_module()
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            fixture = ReleaseRepositoryFixture(root)
            arguments = fixture.arguments(module)

            command_line = [
                str(GENERATOR),
                "--repo-root",
                str(root),
                "--project-yml",
                str(fixture.project_yml),
                "--project-file-path",
                str(fixture.xcodeproj),
                "--configuration",
                "Release",
                "--native-decompiler-live-test-condition",
                "",
                "--swift-active-compilation-conditions",
                "MACSCOPE_FULL_GHOSTTY_SURFACE",
                "--other-swift-flags",
                "",
                "--architectures",
                "arm64",
                "--deployment-target",
                "27.0",
                "--sdk-name",
                "macosx27.0",
                "--sdk-version",
                "27.0",
                "--sdk-build",
                "26A5378i",
                "--developer-dir",
                str(fixture.developer_dir),
                "--swift-executable",
                str(fixture.swift_executable),
                "--output",
                str(fixture.output),
                "--native-decompiler-golden-result",
                str(fixture.native_decompiler_golden_result),
                "--ghostty-source-dir",
                str(fixture.ghostty_source_dir),
                "--ghostty-surface-manifest",
                str(fixture.ghostty_surface_manifest),
                "--ghostty-surface-staged-root",
                str(fixture.ghostty_surface_staged_root),
                "--sleigh-materialization-root",
                str(fixture.sleigh_materialization_root),
                "--machokit-materialization-root",
                str(fixture.machokit_materialization_root),
                "--analysis-worker-executable",
                str(fixture.analysis_worker_executable),
            ]
            with mock.patch.object(sys, "argv", command_line):
                parsed = module.parse_arguments()
            self.assertEqual(parsed.debug_source_identity, "runtime-only")
            with mock.patch.object(sys, "argv", command_line + ["--debug-source-identity", "source-qualified"]):
                self.assertEqual(module.parse_arguments().debug_source_identity, "source-qualified")
            self.assertEqual(
                parsed.ghostty_surface_manifest,
                fixture.ghostty_surface_manifest,
            )
            self.assertEqual(
                parsed.ghostty_surface_staged_root,
                fixture.ghostty_surface_staged_root,
            )
            self.assertEqual(
                module.EXPECTED_GHOSTTY_SURFACE_MANIFEST_FIELDS["source_tree"],
                "de6cd65b35a423d5d6854c6af3a90be20a52d7eb",
            )
            self.assertEqual(
                module.EXPECTED_GHOSTTY_SURFACE_MANIFEST_FIELDS["source_sha256"],
                "ead5d48a8cda07addb59af1f35c6c9f7226bbdbd977b7330afd9714ecec6d8ab",
            )

            arguments.swift_active_compilation_conditions = ""
            with self.assertRaisesRegex(
                module.ProvenanceError,
                "requires exactly one MACSCOPE_FULL_GHOSTTY_SURFACE",
            ):
                module.validate_arguments(arguments)
            arguments.swift_active_compilation_conditions = (
                "MACSCOPE_FULL_GHOSTTY_SURFACE"
            )

            evidence = module.ghostty_surface_evidence(arguments)
            descriptor_bytes = fixture.ghostty_surface_staged_descriptor.read_bytes()
            self.assertEqual(
                evidence["ghostty_surface_staged_descriptor_relative_path"],
                "STAGED_GHOSTTY_SURFACE.json",
            )
            self.assertEqual(
                evidence["ghostty_surface_staged_descriptor_sha256"],
                hashlib.sha256(descriptor_bytes).hexdigest(),
            )
            staged_tree = hashlib.sha256()
            for relative_path in sorted(
                (
                    "STAGED_GHOSTTY_SURFACE.json",
                    "libghostty-internal.a",
                    "Headers/ghostty.h",
                    "Headers/module.modulemap",
                ),
                key=os.fsencode,
            ):
                staged_bytes = (
                    fixture.ghostty_surface_staged_root / relative_path
                ).read_bytes()
                staged_tree.update(relative_path.encode("utf-8"))
                staged_tree.update(b"\0")
                staged_tree.update(str(len(staged_bytes)).encode("ascii"))
                staged_tree.update(b"\0")
                staged_tree.update(hashlib.sha256(staged_bytes).hexdigest().encode("ascii"))
                staged_tree.update(b"\0")
            self.assertEqual(
                evidence["ghostty_surface_staged_tree_sha256"],
                staged_tree.hexdigest(),
            )

            staged_header = (
                fixture.ghostty_surface_staged_root / "Headers/ghostty.h"
            )
            staged_header.write_bytes(b"tampered staged Ghostty header\n")
            with self.assertRaisesRegex(
                module.ProvenanceError,
                "ghostty.h differs from the schema-3 source manifest",
            ):
                module.ghostty_surface_evidence(arguments)

    def test_release_rejects_noncanonical_or_unbound_ghostty_surface_descriptor(
        self,
    ) -> None:
        module = load_generator_module()
        cases = (
            ("missing", "staged root has unexpected entries"),
            ("unknown-field", "schema is not closed"),
            ("wrong-manifest", "does not bind the source manifest"),
            ("wrong-role", "exact leaf roles, paths, and hashes"),
            ("wrong-path", "exact leaf roles, paths, and hashes"),
            ("wrong-hash", "exact leaf roles, paths, and hashes"),
            ("noncanonical", "not canonical JSON"),
            ("duplicate-key", "contains duplicate key"),
        )
        for case, diagnostic in cases:
            with self.subTest(case=case), tempfile.TemporaryDirectory() as temporary_directory:
                fixture = ReleaseRepositoryFixture(Path(temporary_directory))
                descriptor_path = fixture.ghostty_surface_staged_descriptor
                descriptor = json.loads(descriptor_path.read_bytes())
                if case == "missing":
                    descriptor_path.unlink()
                elif case == "unknown-field":
                    descriptor["unknown"] = "rejected"
                    descriptor_path.write_bytes(module.canonical_json(descriptor))
                elif case == "wrong-manifest":
                    descriptor["source_manifest_sha256"] = "0" * 64
                    descriptor_path.write_bytes(module.canonical_json(descriptor))
                elif case == "wrong-role":
                    descriptor["leaves"][0]["role"] = "library"
                    descriptor_path.write_bytes(module.canonical_json(descriptor))
                elif case == "wrong-path":
                    descriptor["leaves"][1]["relative_path"] = "ghostty.h"
                    descriptor_path.write_bytes(module.canonical_json(descriptor))
                elif case == "wrong-hash":
                    descriptor["leaves"][2]["sha256"] = "0" * 64
                    descriptor_path.write_bytes(module.canonical_json(descriptor))
                elif case == "noncanonical":
                    descriptor_path.write_text(
                        json.dumps(descriptor, indent=2) + "\n",
                        encoding="utf-8",
                    )
                else:
                    canonical = descriptor_path.read_bytes()
                    descriptor_path.write_bytes(
                        canonical[:-2] + b',"schema_version":1}\n'
                    )
                with self.assertRaisesRegex(module.ProvenanceError, diagnostic):
                    module.ghostty_surface_evidence(fixture.arguments(module))

    def test_release_rejects_ghostty_leaf_mutation_after_hash_and_symlinked_ancestry(
        self,
    ) -> None:
        module = load_generator_module()
        with tempfile.TemporaryDirectory() as temporary_directory:
            fixture = ReleaseRepositoryFixture(Path(temporary_directory))
            arguments = fixture.arguments(module)
            header = fixture.ghostty_surface_staged_root / "Headers/ghostty.h"
            original_digest = module._digest_provenance_file_at

            def mutate_after_header_hash(
                parent_descriptor: int,
                name: str,
                maximum_bytes: int,
                label: str,
                *,
                retain_payload: bool = False,
            ):
                result = original_digest(
                    parent_descriptor,
                    name,
                    maximum_bytes,
                    label,
                    retain_payload=retain_payload,
                )
                if name == "module.modulemap":
                    header.write_bytes(b"mutated after the header hash\n")
                return result

            with mock.patch.object(
                module,
                "_digest_provenance_file_at",
                side_effect=mutate_after_header_hash,
            ):
                with self.assertRaisesRegex(module.ProvenanceError, "changed"):
                    module.ghostty_surface_evidence(arguments)

        with tempfile.TemporaryDirectory() as temporary_directory:
            fixture = ReleaseRepositoryFixture(Path(temporary_directory))
            alias = fixture.root / "StagedAlias"
            alias.symlink_to(fixture.ghostty_surface_staged_root, target_is_directory=True)
            arguments = fixture.arguments(module)
            arguments.ghostty_surface_staged_root = alias
            with self.assertRaisesRegex(
                module.ProvenanceError,
                "ancestry must contain only ordinary directory",
            ):
                module.ghostty_surface_evidence(arguments)

    def test_release_accepts_schema_two_sleigh_through_strict_verifier(self) -> None:
        module = load_generator_module()
        with tempfile.TemporaryDirectory() as temporary_directory:
            fixture = ReleaseRepositoryFixture(Path(temporary_directory))
            arguments = fixture.arguments(module)
            fixture.rewrite_embedded_package_identity(schema_version=2)
            fixture.write_golden_result()
            verified_roots: list[Path] = []

            def strict_verifier(root: Path) -> dict[str, object]:
                verified_roots.append(root)
                return json.loads(
                    (root / "MATERIALIZATION.json").read_text(encoding="utf-8")
                )

            arguments.sleigh_materialization_verifier = strict_verifier
            payload = module.generate(arguments, tool_runner=FixtureToolRunner())

            self.assertEqual(payload["sleigh_materialization_schema_version"], 2)
            self.assertEqual(
                payload["sleigh_materialization_component_id"],
                "sleigh-native-source-dcp03b4",
            )
            self.assertGreaterEqual(len(verified_roots), 2)
            self.assertTrue(
                all(
                    root == fixture.sleigh_materialization_root.resolve(strict=True)
                    for root in verified_roots
                )
            )

    def test_strict_sleigh_loader_supports_dataclass_module(self) -> None:
        module = load_generator_module()
        verifier = module._load_strict_sleigh_materialization_verifier(
            REPOSITORY_ROOT
        )
        self.assertTrue(callable(verifier))

    def test_native_decompiler_target_and_tracked_build_surface_are_selected(self) -> None:
        module = load_generator_module()
        with tempfile.TemporaryDirectory() as temporary_directory:
            fixture = ReleaseRepositoryFixture(Path(temporary_directory))

            selected = module.selected_source_paths(
                fixture.root,
                fixture.project_yml,
                fixture.project_yml.read_text(encoding="utf-8"),
            )

            expected_service_inputs = {
                "MacScope/NativeDecompilerXPCService/Info.plist",
                "MacScope/NativeDecompilerXPCService/ServiceMain.swift",
                "MacScope/NativeDecompilerXPCService/Bridge/NativeBridge.mm",
            }
            expected_build_inputs = {
                path.relative_to(fixture.root).as_posix()
                for path in (fixture.root / "Scripts/native-decompiler-xpc").iterdir()
                if path.is_file()
            }
            self.assertTrue(expected_service_inputs.issubset(selected))
            self.assertTrue(expected_build_inputs.issubset(selected))
            self.assertFalse(
                any("MATERIALIZATION" in path or "/package/" in path for path in selected)
            )

    def test_native_decompiler_build_surface_without_target_fails_closed(self) -> None:
        module = load_generator_module()
        with tempfile.TemporaryDirectory() as temporary_directory:
            fixture = ReleaseRepositoryFixture(Path(temporary_directory))
            project_text = fixture.project_yml.read_text(encoding="utf-8")
            native_target = """\
  NativeDecompilerXPCService:
    sources:
      - path: NativeDecompilerXPCService
        excludes:
          - Info.plist
"""
            project_text = project_text.replace(native_target, "", 1)

            with self.assertRaisesRegex(
                module.ProvenanceError,
                "NativeDecompilerXPCService",
            ):
                module.selected_source_paths(
                    fixture.root,
                    fixture.project_yml,
                    project_text,
                )

    def test_native_decompiler_target_without_script_root_fails_closed(self) -> None:
        module = load_generator_module()
        with tempfile.TemporaryDirectory() as temporary_directory:
            fixture = ReleaseRepositoryFixture(Path(temporary_directory))
            shutil.rmtree(fixture.root / "Scripts/native-decompiler-xpc")

            with self.assertRaisesRegex(
                module.ProvenanceError,
                "selected build input is missing",
            ):
                module.selected_source_paths(
                    fixture.root,
                    fixture.project_yml,
                    fixture.project_yml.read_text(encoding="utf-8"),
                )

    def test_recursive_filename_exclude_supports_finder_metadata(self) -> None:
        module = load_generator_module()

        self.assertTrue(module.is_excluded(".DS_Store", ("**/.DS_Store",)))
        self.assertTrue(module.is_excluded("Features/.DS_Store", ("**/.DS_Store",)))
        self.assertTrue(
            module.is_excluded("Resources/Assets.xcassets/.DS_Store", ("**/.DS_Store",))
        )
        self.assertFalse(module.is_excluded("Features/Assistant/View.swift", ("**/.DS_Store",)))

    def test_recursive_filename_exclude_rejects_broad_wildcards(self) -> None:
        module = load_generator_module()

        for pattern in ("**/*.swift", "**/Nested/.DS_Store", "**/"):
            with self.subTest(pattern=pattern):
                with self.assertRaisesRegex(module.ProvenanceError, "unsupported wildcard"):
                    module.is_excluded("Features/Assistant/View.swift", (pattern,))

    def test_real_project_closure_is_bounded_to_top_level_targets_and_includes_gate_authority(self) -> None:
        module = load_generator_module()
        project_yml = REPOSITORY_ROOT / "MacScope" / "project.yml"
        third_party = module.third_party_declared_paths(REPOSITORY_ROOT)
        selected = module.selected_source_paths(
            REPOSITORY_ROOT,
            project_yml,
            project_yml.read_text(encoding="utf-8"),
        )

        self.assertGreaterEqual(
            module.MAX_THIRD_PARTY_DECLARED_FILES - len(third_party),
            10_000,
        )
        self.assertGreaterEqual(module.MAX_SELECTED_FILES - len(selected), 20_000)
        self.assertIn(
            "MacScope/Services/Phase2/Phase2ModelQualificationHarness.swift",
            selected,
        )
        self.assertIn(
            "MacScope/Services/Phase2/QualificationGate/Phase2ModelQualificationReport.swift",
            selected,
        )
        self.assertGreater(
            sum(path.startswith("MacScope/Tests/CoreTests/") for path in selected),
            100,
        )
        self.assertIn("THIRD_PARTY_COMPONENTS.yml", selected)
        self.assertIn("THIRD_PARTY_NOTICES.md", selected)
        self.assertIn("ThirdParty/GhosttyVT/LICENSE.txt", selected)
        self.assertIn("ThirdParty/ZigToolchain/LICENSE.txt", selected)
        self.assertIn("MacScope/ShellBrokerService/main.swift", selected)
        self.assertIn("MacScope/ShellBrokerService/LaunchAgent.plist", selected)
        self.assertIn("Scripts/dependencies/stage_verified_ghostty_surface.py", selected)

    def test_third_party_manifest_rejects_duplicate_keys_and_unknown_component_fields(self) -> None:
        module = load_generator_module()
        with tempfile.TemporaryDirectory() as temporary_directory:
            fixture = ReleaseRepositoryFixture(Path(temporary_directory))
            manifest_path = fixture.root / "THIRD_PARTY_COMPONENTS.yml"
            original = manifest_path.read_text(encoding="utf-8")
            manifest_path.write_text(
                original.replace(
                    '  "schema_version": 1,',
                    '  "schema_version": 1,\n  "schema_version": 1,',
                    1,
                ),
                encoding="utf-8",
            )
            with self.assertRaisesRegex(module.ProvenanceError, "duplicate key"):
                module.load_third_party_manifest(fixture.root)

            manifest = json.loads(original)
            manifest["components"][0]["unexpected"] = True
            manifest_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
            with self.assertRaisesRegex(module.ProvenanceError, "unsupported schema"):
                module.load_third_party_manifest(fixture.root)

    def test_third_party_manifest_rejects_empty_inventory(self) -> None:
        module = load_generator_module()
        with tempfile.TemporaryDirectory() as temporary_directory:
            fixture = ReleaseRepositoryFixture(Path(temporary_directory))
            manifest_path = fixture.root / "THIRD_PARTY_COMPONENTS.yml"
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
            manifest["components"] = []
            manifest_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")

            with self.assertRaisesRegex(module.ProvenanceError, r"1\.\.512 entries"):
                module.load_third_party_manifest(fixture.root)

    def test_third_party_declared_path_must_exist(self) -> None:
        module = load_generator_module()
        with tempfile.TemporaryDirectory() as temporary_directory:
            fixture = ReleaseRepositoryFixture(Path(temporary_directory))
            manifest_path = fixture.root / "THIRD_PARTY_COMPONENTS.yml"
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
            manifest["components"][0]["tracked_paths"].append(
                "ThirdParty/MissingDependencyRecord"
            )
            manifest_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")

            with self.assertRaisesRegex(module.ProvenanceError, "selected build input is missing"):
                module.third_party_declared_paths(fixture.root)

    def test_third_party_declared_path_bound_allows_ceiling_and_rejects_overflow(self) -> None:
        module = load_generator_module()
        with tempfile.TemporaryDirectory() as temporary_directory:
            fixture = ReleaseRepositoryFixture(Path(temporary_directory))
            declared = module.third_party_declared_paths(fixture.root)
            boundary = len(declared)

            with mock.patch.object(
                module,
                "MAX_THIRD_PARTY_DECLARED_FILES",
                boundary,
            ):
                self.assertEqual(
                    module.third_party_declared_paths(fixture.root),
                    declared,
                )
            with mock.patch.object(
                module,
                "MAX_THIRD_PARTY_DECLARED_FILES",
                boundary - 1,
            ), self.assertRaisesRegex(
                module.ProvenanceError,
                "third-party declared path count exceeds fixed bound",
            ):
                module.third_party_declared_paths(fixture.root)

    def test_ineligible_payload_contains_no_release_or_runtime_claims(self) -> None:
        module = load_generator_module()
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            output = root / "MacScopeBuildProvenance.json"
            arguments = module.ProvenanceArguments(
                repository_root=root / "missing-repository",
                project_yml=root / "missing-project.yml",
                project_file_path=root / "missing.xcodeproj",
                configuration="Debug",
                architectures="arm64",
                deployment_target="27.0",
                sdk_name="macosx27.0",
                sdk_version="27.0",
                sdk_build="26A5378i",
                developer_dir=root / "missing-developer",
                swift_executable=root / "missing-swiftc",
                output=output,
            )

            payload = module.ineligible_payload(arguments)

            expected = {
                "ai_worker_bundle_identifier": "org.macscope.app.AIAgentWorker",
                "app_bundle_identifier": "org.macscope.app",
                "architecture": "arm64",
                "configuration": "Debug",
                "deployment_target": "27.0",
                "git_head_commit": None,
                "git_head_tree": None,
                "project_yml_sha256": None,
                "third_party_manifest_sha256": None,
                "third_party_notices_sha256": None,
                "third_party_component_ids": [],
                "third_party_component_count": 0,
                "third_party_distribution_status": None,
                "third_party_public_distribution_approved": False,
                "qualification_eligible": False,
                "repository_clean": False,
                "schema_version": 1,
                "sdk_build": "26A5378i",
                "sdk_name": "macosx27.0",
                "sdk_version": "27.0",
                "selected_build_inputs_sha256": None,
                "swift_compiler_version": None,
                "swift_language_version": "6.0",
                "swift_target_triple": None,
                "xcode_build": None,
                "xcode_version": None,
                "xcodegen_version": None,
            }
            self.assertEqual(payload, expected)

    def test_runtime_only_debug_never_resolves_or_hashes_source_authority(self) -> None:
        module = load_generator_module()
        with tempfile.TemporaryDirectory() as temporary_directory:
            fixture = ReleaseRepositoryFixture(Path(temporary_directory))
            arguments = fixture.arguments(module, configuration="Debug")
            with mock.patch.object(module, "resolve_source_authority", side_effect=AssertionError("source authority walk")), \
                 mock.patch.object(module, "selected_input_hashes", side_effect=AssertionError("source hash walk")), \
                 mock.patch.object(module, "selected_source_paths", side_effect=AssertionError("source membership walk")):
                payload = module.generate(arguments, tool_runner=lambda *_: self.fail("Release tool discovery"))
            for key in ("git_head_commit", "git_head_tree", "selected_build_inputs_sha256"):
                self.assertIsNone(payload[key], key)
            self.assertFalse(payload["qualification_eligible"])
            self.assertIn("native_decompiler_golden_result", payload)
            self.assertRegex(payload["native_decompiler_embedded_tree_sha256"], r"^[0-9a-f]{64}$")

    def test_runtime_only_debug_still_rejects_embedded_runtime_mutation(self) -> None:
        module = load_generator_module()
        with tempfile.TemporaryDirectory() as temporary_directory:
            fixture = ReleaseRepositoryFixture(Path(temporary_directory))
            arguments = fixture.arguments(module, configuration="Debug")
            original = module.debug_runtime_payload
            def mutate_after_capture(arguments):
                payload = original(arguments)
                arguments.native_decompiler_golden_result.write_bytes(b"{}\n")
                return payload
            with mock.patch.object(module, "debug_runtime_payload", side_effect=mutate_after_capture):
                with self.assertRaises(module.ProvenanceError):
                    module.generate(arguments, tool_runner=lambda *_: self.fail("Release tool discovery"))

    def test_debug_source_mode_does_not_change_release_payload(self) -> None:
        module = load_generator_module()
        with tempfile.TemporaryDirectory() as temporary_directory:
            fixture = ReleaseRepositoryFixture(Path(temporary_directory))
            arguments = fixture.arguments(module)
            ordinary = module.generate(arguments, tool_runner=FixtureToolRunner())
            arguments.debug_source_identity = "source-qualified"
            opted_in = module.generate(arguments, tool_runner=FixtureToolRunner())
            self.assertEqual(ordinary, opted_in)
            self.assertTrue(opted_in["qualification_eligible"])

    def test_debug_binds_embedded_runtime_without_release_eligibility(self) -> None:
        module = load_generator_module()
        with tempfile.TemporaryDirectory() as temporary_directory:
            fixture = ReleaseRepositoryFixture(Path(temporary_directory))
            arguments = fixture.arguments(module, configuration="Debug")
            arguments.sleigh_materialization_root = None
            arguments.debug_source_identity = "source-qualified"
            payload = module.generate(
                arguments,
                tool_runner=lambda *_: self.fail("Debug must not invoke release tool discovery"),
            )

            self.assertFalse(payload["qualification_eligible"])
            self.assertFalse(payload["repository_clean"])
            self.assertEqual(payload["configuration"], "Debug")
            self.assertEqual(payload["git_head_commit"], run_git(fixture.root, "rev-parse", "HEAD"))
            self.assertEqual(payload["git_head_tree"], run_git(fixture.root, "rev-parse", "HEAD^{tree}"))
            release_payload = module.generate(fixture.arguments(module), tool_runner=FixtureToolRunner())
            self.assertEqual(payload["selected_build_inputs_sha256"], release_payload["selected_build_inputs_sha256"])
            self.assertIn("native_decompiler_golden_result", payload)
            self.assertRegex(
                payload["native_decompiler_embedded_tree_sha256"], r"^[0-9a-f]{64}$"
            )
            self.assertEqual(
                payload["xcode_build"],
                payload["native_decompiler_golden_result"]["xcodeBuild"],
            )

    def test_debug_keeps_source_identities_null_when_dirty_or_unavailable(self) -> None:
        module = load_generator_module()
        for state in ("dirty", "unavailable"):
            with self.subTest(state=state), tempfile.TemporaryDirectory() as temporary_directory:
                fixture = ReleaseRepositoryFixture(Path(temporary_directory))
                if state == "dirty":
                    (fixture.root / "MacScope/App/App.swift").write_text("// dirty source\n")
                else:
                    shutil.rmtree(fixture.root / ".git")
                arguments = fixture.arguments(module, configuration="Debug")
                arguments.debug_source_identity = "source-qualified"
                payload = module.generate(arguments,
                    tool_runner=lambda *_: self.fail("Debug must not discover Release tools"))
                self.assertFalse(payload["qualification_eligible"])
                self.assertFalse(payload["repository_clean"])
                for key in ("git_head_commit", "git_head_tree", "selected_build_inputs_sha256"):
                    self.assertIsNone(payload[key], key)
                self.assertIn("native_decompiler_golden_result", payload)

    def test_release_emits_complete_bounded_content_addressed_evidence(self) -> None:
        module = load_generator_module()
        runner = FixtureToolRunner()
        with tempfile.TemporaryDirectory() as temporary_directory:
            fixture = ReleaseRepositoryFixture(Path(temporary_directory))
            expected_head = run_git(fixture.root, "rev-parse", "HEAD")
            expected_tree = run_git(fixture.root, "rev-parse", "HEAD^{tree}")

            payload = module.generate(fixture.arguments(module), tool_runner=runner)

            self.assertEqual(
                set(payload),
                {
                    "schema_version",
                    "qualification_eligible",
                    "configuration",
                    "git_head_commit",
                    "git_head_tree",
                    "repository_clean",
                    "selected_build_inputs_sha256",
                    "project_yml_sha256",
                    "dependency_root_authority",
                    "ghostty_source_dir_sha256",
                    "sleigh_materialization_root_sha256",
                    "sleigh_materialization_schema_version",
                    "sleigh_materialization_component_id",
                    "sleigh_materialization_manifest_sha256",
                    "sleigh_materialization_tree_sha256",
                    "ghostty_surface_compilation_condition",
                    "ghostty_surface_source_manifest_sha256",
                    "ghostty_surface_source_revision",
                    "ghostty_surface_source_tree",
                    "ghostty_surface_source_sha256",
                    "ghostty_surface_external_io_abi_version",
                    "ghostty_surface_build_profile_sha256",
                    "ghostty_surface_staged_tree_sha256",
                    "ghostty_surface_staged_descriptor_relative_path",
                    "ghostty_surface_staged_descriptor_sha256",
                    "ghostty_surface_archive_relative_path",
                    "ghostty_surface_archive_sha256",
                    "ghostty_surface_header_relative_path",
                    "ghostty_surface_header_sha256",
                    "ghostty_surface_module_map_relative_path",
                    "ghostty_surface_module_map_sha256",
                    "machokit_materialization_root_sha256",
                    "machokit_version",
                    "machokit_revision",
                    "machokit_source_archive_sha256",
                    "machokit_upstream_tree_sha256",
                    "machokit_materialization_tree_sha256",
                    "machokit_governed_source_identity",
                    "machokit_materialization_manifest_sha256",
                    "machokit_analysis_worker_compiled_identity",
                    "machokit_analysis_worker_executable_sha256",
                    "machokit_analysis_worker_executable_size",
                    "third_party_manifest_sha256",
                    "third_party_notices_sha256",
                    "third_party_component_ids",
                    "third_party_component_count",
                    "third_party_distribution_status",
                    "third_party_public_distribution_approved",
                    "xcodegen_version",
                    "xcode_version",
                    "xcode_build",
                    "swift_compiler_version",
                    "swift_target_triple",
                    "native_decompiler_golden_result_sha256",
                    "native_decompiler_golden_result",
                    "native_decompiler_embedded_manifest_sha256",
                    "native_decompiler_embedded_tree_sha256",
                    "native_decompiler_embedded_decompiler_archive_sha256",
                    "native_decompiler_embedded_sleigh_archive_sha256",
                    "native_decompiler_embedded_service_bundle_identifier",
                    "native_decompiler_embedded_service_info_plist_sha256",
                    "native_decompiler_embedded_service_executable_sha256",
                    "native_decompiler_embedded_service_code_resources_sha256",
                    "sdk_name",
                    "sdk_version",
                    "sdk_build",
                    "swift_language_version",
                    "architecture",
                    "deployment_target",
                    "app_bundle_identifier",
                    "ai_worker_bundle_identifier",
                },
            )
            self.assertTrue(payload["qualification_eligible"])
            self.assertTrue(payload["repository_clean"])
            self.assertEqual(payload["git_head_commit"], expected_head)
            self.assertEqual(payload["git_head_tree"], expected_tree)
            self.assertRegex(payload["selected_build_inputs_sha256"], r"^[0-9a-f]{64}$")
            self.assertEqual(
                payload["project_yml_sha256"],
                hashlib.sha256(fixture.project_yml.read_bytes()).hexdigest(),
            )
            self.assertEqual(
                payload["dependency_root_authority"],
                "xcode-resolved-build-settings",
            )
            self.assertEqual(
                payload["ghostty_source_dir_sha256"],
                hashlib.sha256(
                    os.fsencode(str(fixture.ghostty_source_dir.resolve(strict=True)))
                ).hexdigest(),
            )
            self.assertEqual(
                payload["sleigh_materialization_root_sha256"],
                hashlib.sha256(
                    os.fsencode(
                        str(fixture.sleigh_materialization_root.resolve(strict=True))
                    )
                ).hexdigest(),
            )
            sleigh_manifest = json.loads(
                (
                    fixture.sleigh_materialization_root / "MATERIALIZATION.json"
                ).read_text(encoding="utf-8")
            )
            self.assertEqual(payload["sleigh_materialization_schema_version"], 1)
            self.assertEqual(
                payload["sleigh_materialization_component_id"],
                "sleigh-native-dcp03b4",
            )
            self.assertEqual(
                payload["sleigh_materialization_manifest_sha256"],
                hashlib.sha256(
                    (
                        fixture.sleigh_materialization_root / "MATERIALIZATION.json"
                    ).read_bytes()
                ).hexdigest(),
            )
            self.assertEqual(
                payload["sleigh_materialization_tree_sha256"],
                sleigh_manifest["package"]["treeSha256"],
            )
            self.assertEqual(
                payload["ghostty_surface_compilation_condition"],
                "MACSCOPE_FULL_GHOSTTY_SURFACE",
            )
            self.assertEqual(
                payload["ghostty_surface_source_manifest_sha256"],
                hashlib.sha256(fixture.ghostty_surface_manifest.read_bytes()).hexdigest(),
            )
            self.assertEqual(
                payload["ghostty_surface_source_revision"],
                module.EXPECTED_GHOSTTY_SURFACE_MANIFEST_FIELDS["source_revision"],
            )
            self.assertEqual(payload["ghostty_surface_external_io_abi_version"], 1)
            self.assertEqual(
                payload["ghostty_surface_staged_descriptor_relative_path"],
                "STAGED_GHOSTTY_SURFACE.json",
            )
            self.assertEqual(
                payload["ghostty_surface_staged_descriptor_sha256"],
                hashlib.sha256(
                    fixture.ghostty_surface_staged_descriptor.read_bytes()
                ).hexdigest(),
            )
            self.assertEqual(
                payload["ghostty_surface_archive_relative_path"],
                "libghostty-internal.a",
            )
            self.assertEqual(
                payload["ghostty_surface_header_relative_path"],
                "Headers/ghostty.h",
            )
            self.assertEqual(
                payload["ghostty_surface_module_map_relative_path"],
                "Headers/module.modulemap",
            )
            self.assertEqual(
                payload["machokit_materialization_root_sha256"],
                hashlib.sha256(
                    os.fsencode(
                        str(fixture.machokit_materialization_root.resolve(strict=True))
                    )
                ).hexdigest(),
            )
            self.assertEqual(
                {
                    key.removeprefix("machokit_"): value
                    for key, value in payload.items()
                    if key
                    in {
                        "machokit_version",
                        "machokit_revision",
                        "machokit_source_archive_sha256",
                        "machokit_upstream_tree_sha256",
                        "machokit_materialization_tree_sha256",
                        "machokit_governed_source_identity",
                    }
                },
                module.MACHOKIT_EXPECTED_IDENTITY,
            )
            self.assertEqual(
                payload["machokit_materialization_manifest_sha256"],
                hashlib.sha256(
                    (fixture.machokit_materialization_root / "MATERIALIZATION.json").read_bytes()
                ).hexdigest(),
            )
            compiled_identity = load_machokit_compiled_identity_verifier()
            self.assertEqual(
                payload["machokit_analysis_worker_compiled_identity"],
                {
                    "schema": "macscope-machokit-compiled-identity-v1",
                    "revision": compiled_identity.MACHOKIT_REVISION,
                    "governed_source_identity": (
                        compiled_identity.GOVERNED_SOURCE_IDENTITY
                    ),
                },
            )
            worker_bytes = fixture.analysis_worker_executable.read_bytes()
            self.assertEqual(
                payload["machokit_analysis_worker_executable_sha256"],
                hashlib.sha256(worker_bytes).hexdigest(),
            )
            self.assertEqual(
                payload["machokit_analysis_worker_executable_size"],
                len(worker_bytes),
            )
            self.assertEqual(
                payload["third_party_manifest_sha256"],
                hashlib.sha256(
                    (fixture.root / "THIRD_PARTY_COMPONENTS.yml").read_bytes()
                ).hexdigest(),
            )
            self.assertEqual(
                payload["third_party_notices_sha256"],
                hashlib.sha256(
                    (fixture.root / "THIRD_PARTY_NOTICES.md").read_bytes()
                ).hexdigest(),
            )
            self.assertEqual(payload["third_party_component_ids"], ["fixture-tool"])
            self.assertEqual(payload["third_party_component_count"], 1)
            self.assertEqual(
                payload["third_party_distribution_status"],
                "private-development-only",
            )
            self.assertFalse(payload["third_party_public_distribution_approved"])
            self.assertEqual(payload["xcodegen_version"], "2.45.4")
            self.assertEqual(payload["xcode_version"], "27.0")
            self.assertEqual(payload["xcode_build"], "27A5218g")
            self.assertEqual(payload["swift_compiler_version"], "6.4")
            self.assertEqual(payload["swift_target_triple"], "arm64-apple-macosx27.0.0")
            golden_bytes = fixture.native_decompiler_golden_result.read_bytes()
            self.assertEqual(
                payload["native_decompiler_golden_result_sha256"],
                hashlib.sha256(golden_bytes).hexdigest(),
            )
            self.assertEqual(
                payload["native_decompiler_golden_result"],
                fixture.golden_result_payload(),
            )
            package_hashes = fixture.embedded_package_hashes()
            self.assertEqual(
                payload["native_decompiler_embedded_manifest_sha256"],
                package_hashes["manifest"],
            )
            self.assertEqual(
                payload["native_decompiler_embedded_tree_sha256"],
                package_hashes["tree"],
            )
            self.assertEqual(
                payload["native_decompiler_embedded_decompiler_archive_sha256"],
                package_hashes["decompiler"],
            )
            self.assertEqual(
                payload["native_decompiler_embedded_sleigh_archive_sha256"],
                package_hashes["sleigh"],
            )
            self.assertEqual(
                payload["native_decompiler_embedded_service_bundle_identifier"],
                "org.macscope.app.NativeDecompiler",
            )
            self.assertEqual(
                payload["native_decompiler_embedded_service_info_plist_sha256"],
                package_hashes["service_info"],
            )
            self.assertEqual(
                payload["native_decompiler_embedded_service_executable_sha256"],
                package_hashes["service_executable"],
            )
            self.assertEqual(
                payload["native_decompiler_embedded_service_code_resources_sha256"],
                package_hashes["service_code_resources"],
            )
            self.assertEqual(len(fixture.output.read_bytes()), len(module.canonical_json(payload)))
            self.assertLessEqual(len(fixture.output.read_bytes()), module.MAX_OUTPUT_BYTES)
            self.assertEqual(runner.calls[0], (str(fixture.root / "ThirdParty/XcodeGen/bin/xcodegen"), "version"))
            self.assertEqual(runner.calls[1][:2], (str(fixture.root / "ThirdParty/XcodeGen/bin/xcodegen"), "generate"))
            self.assertEqual(runner.calls[2][:4], ("/usr/bin/xcrun", "xcodebuild", "-convert-project", "Xcode Project"))
            self.assertEqual(runner.calls[3], ("/usr/bin/xcodebuild", "-version"))
            self.assertEqual(
                runner.calls[4],
                (str(fixture.swift_executable.resolve()), "--version"),
            )

    def test_release_requires_exact_canonical_embedded_native_decompiler_evidence(self) -> None:
        module = load_generator_module()
        with tempfile.TemporaryDirectory() as temporary_directory:
            fixture = ReleaseRepositoryFixture(Path(temporary_directory))
            arguments = fixture.arguments(module)
            expected = fixture.golden_result_payload()
            encoded = fixture.native_decompiler_golden_result.read_bytes()
            evidence = module.native_decompiler_golden_evidence(
                arguments,
                head_commit=expected["wrapperGitRevision"],
                tools={
                    "xcodeVersion": "unused",
                    "xcode_version": "27.0",
                    "xcode_build": "27A5218g",
                    "swift_compiler_version": "6.4",
                    "swift_target_triple": "arm64-apple-macosx27.0.0",
                },
            )
            self.assertEqual(evidence["native_decompiler_golden_result"], expected)
            self.assertEqual(
                evidence["native_decompiler_golden_result_sha256"],
                hashlib.sha256(encoded).hexdigest(),
            )
            self.assertEqual(
                evidence["native_decompiler_embedded_tree_sha256"],
                fixture.embedded_package_hashes()["tree"],
            )
            self.assertNotIn("/Users/", encoded.decode("utf-8"))
            self.assertNotIn("/private/tmp/", encoded.decode("utf-8"))

    def test_release_verifiers_accept_critical_map_summary_drift(self) -> None:
        module = load_generator_module()
        missing = APPLE_SILICON_CRITICAL_FILE_RELATIVE_PATHS[1]
        for verifier in ("direct", "snapshot"):
            with self.subTest(verifier=verifier), tempfile.TemporaryDirectory() as temporary_directory:
                fixture = ReleaseRepositoryFixture(Path(temporary_directory))
                arguments = fixture.arguments(module)
                fixture.rewrite_embedded_package_identity(
                    omitted_critical_paths=frozenset({missing})
                )
                golden = fixture.golden_result_payload()
                fixture.write_golden_result(golden)
                if verifier == "direct":
                    evidence = module.embedded_native_decompiler_package_evidence(
                        fixture.native_decompiler_golden_result,
                        golden,
                    )
                else:
                    evidence = module.native_decompiler_golden_evidence(
                        arguments,
                        head_commit=run_git(fixture.root, "rev-parse", "HEAD"),
                        tools={
                            "xcode_version": "27.0",
                            "xcode_build": "27A5218g",
                            "swift_compiler_version": "6.4",
                            "swift_target_triple": "arm64-apple-macosx27.0.0",
                        },
                    )
                hashes = fixture.embedded_package_hashes()
                self.assertEqual(evidence["native_decompiler_embedded_tree_sha256"], hashes["tree"])
                self.assertEqual(
                    evidence["native_decompiler_embedded_manifest_sha256"],
                    hashes["manifest"],
                )

    def test_release_verifiers_use_complete_identity_for_synthetic_resource_substitution(self) -> None:
        module = load_generator_module()
        literal = APPLE_SILICON_CRITICAL_FILE_RELATIVE_PATHS[1]
        substitutions = {
            "generic": "AARCH64_Generic.sla",
            "suffix": "000_AARCH64_AppleSilicon.sla",
        }
        for substitution, filename in substitutions.items():
            for verifier in ("direct", "snapshot"):
                with (
                    self.subTest(substitution=substitution, verifier=verifier),
                    tempfile.TemporaryDirectory() as temporary_directory,
                ):
                    fixture = ReleaseRepositoryFixture(Path(temporary_directory))
                    arguments = fixture.arguments(module)
                    package_root = (
                        fixture.native_decompiler_golden_result.parent
                        / "NativeDecompilerPackage/package"
                    )
                    literal_path = package_root / literal
                    literal_path.unlink()
                    (literal_path.parent / filename).write_bytes(
                        f"fixture-{substitution}-substitution\n".encode()
                    )
                    fixture.rewrite_embedded_package_identity()
                    golden = fixture.golden_result_payload()
                    fixture.write_golden_result(golden)
                    with self.assertRaisesRegex(
                        module.ProvenanceError, "frozen Apple Silicon resource"
                    ):
                        if verifier == "direct":
                            module.embedded_native_decompiler_package_evidence(
                                fixture.native_decompiler_golden_result,
                                golden,
                            )
                        else:
                            module.native_decompiler_golden_evidence(
                                arguments,
                                head_commit=run_git(fixture.root, "rev-parse", "HEAD"),
                                tools={
                                    "xcode_version": "27.0",
                                    "xcode_build": "27A5218g",
                                    "swift_compiler_version": "6.4",
                                    "swift_target_triple": "arm64-apple-macosx27.0.0",
                                },
                            )

    def test_release_verifiers_reject_untruthful_critical_maps(self) -> None:
        module = load_generator_module()
        mutations = {
            "empty": {},
            "zero-digest": {"lib/libdecomp.a": "0" * 64},
            "fabricated": {"totally/made/up.sla": "1" * 64},
        }
        for mutation, critical_map in mutations.items():
            for verifier in ("direct", "snapshot"):
                with (
                    self.subTest(mutation=mutation, verifier=verifier),
                    tempfile.TemporaryDirectory() as temporary_directory,
                ):
                    fixture = ReleaseRepositoryFixture(Path(temporary_directory))
                    arguments = fixture.arguments(module)
                    fixture.rewrite_embedded_package_identity(
                        critical_override=critical_map
                    )
                    golden = fixture.golden_result_payload()
                    fixture.write_golden_result(golden)
                    with self.assertRaisesRegex(
                        module.ProvenanceError, "critical-file identity"
                    ):
                        if verifier == "direct":
                            module.embedded_native_decompiler_package_evidence(
                                fixture.native_decompiler_golden_result, golden
                            )
                        else:
                            module.native_decompiler_golden_evidence(
                                arguments,
                                head_commit=run_git(fixture.root, "rev-parse", "HEAD"),
                                tools={
                                    "xcode_version": "27.0",
                                    "xcode_build": "27A5218g",
                                    "swift_compiler_version": "6.4",
                                    "swift_target_triple": "arm64-apple-macosx27.0.0",
                                },
                            )

    def test_native_decompiler_evidence_is_derived_only_from_the_app_output(self) -> None:
        module = load_generator_module()
        with tempfile.TemporaryDirectory() as temporary_directory:
            fixture = ReleaseRepositoryFixture(Path(temporary_directory))
            arguments = fixture.arguments(module)
            tools = {
                "xcode_version": "27.0",
                "xcode_build": "27A5218g",
                "swift_compiler_version": "6.4",
                "swift_target_triple": "arm64-apple-macosx27.0.0",
            }
            wrong_output = module.ProvenanceArguments(
                **{
                    **arguments.__dict__,
                    "output": fixture.root
                    / "Build/Other.app/Contents/Resources/MacScopeBuildProvenance.json",
                }
            )
            with self.assertRaisesRegex(module.ProvenanceError, "output|MacScope.app"):
                module.native_decompiler_golden_evidence(
                    wrong_output,
                    head_commit=run_git(fixture.root, "rev-parse", "HEAD"),
                    tools=tools,
                )

            sibling_golden = module.ProvenanceArguments(
                **{
                    **arguments.__dict__,
                    "native_decompiler_golden_result": fixture.root
                    / "Build/Other.app/Contents/XPCServices/"
                    "NativeDecompilerXPCService.xpc/Contents/Resources/"
                    "NativeDecompilerBridgeGolden.json",
                }
            )
            with self.assertRaisesRegex(module.ProvenanceError, "derived|embedded XPC"):
                module.native_decompiler_golden_evidence(
                    sibling_golden,
                    head_commit=run_git(fixture.root, "rev-parse", "HEAD"),
                    tools=tools,
                )

    def test_release_rejects_symlinked_embedded_service_ancestor(self) -> None:
        module = load_generator_module()
        relative_ancestors = (
            "",
            "Contents",
            "Contents/Resources",
            "Contents/XPCServices",
            "Contents/XPCServices/NativeDecompilerXPCService.xpc",
            "Contents/XPCServices/NativeDecompilerXPCService.xpc/Contents",
            "Contents/XPCServices/NativeDecompilerXPCService.xpc/Contents/Resources",
            (
                "Contents/XPCServices/NativeDecompilerXPCService.xpc/Contents/"
                "Resources/NativeDecompilerPackage"
            ),
            "Contents/XPCServices/NativeDecompilerXPCService.xpc/Contents/MacOS",
            "Contents/XPCServices/NativeDecompilerXPCService.xpc/Contents/_CodeSignature",
        )
        for index, relative in enumerate(relative_ancestors):
            with self.subTest(relative=relative), tempfile.TemporaryDirectory() as temporary_directory:
                fixture = ReleaseRepositoryFixture(Path(temporary_directory))
                arguments = fixture.arguments(module)
                app_root = fixture.output.parents[2]
                component = app_root / relative if relative else app_root
                outside = fixture.root / f"outside-{index}"
                component.rename(outside)
                component.symlink_to(outside, target_is_directory=True)

                with self.assertRaisesRegex(
                    module.ProvenanceError,
                    "symbolic|ordinary directory|symlink",
                ):
                    module.native_decompiler_golden_evidence(
                        arguments,
                        head_commit=run_git(fixture.root, "rev-parse", "HEAD"),
                        tools={
                            "xcode_version": "27.0",
                            "xcode_build": "27A5218g",
                            "swift_compiler_version": "6.4",
                            "swift_target_triple": "arm64-apple-macosx27.0.0",
                        },
                    )

    def test_release_rejects_symlinked_ancestor_above_application_bundle(self) -> None:
        module = load_generator_module()
        with tempfile.TemporaryDirectory() as temporary_directory:
            fixture = ReleaseRepositoryFixture(Path(temporary_directory))
            arguments = fixture.arguments(module)
            build_root = fixture.root / "Build"
            outside = fixture.root / "outside-build"
            build_root.rename(outside)
            build_root.symlink_to(outside, target_is_directory=True)

            with self.assertRaisesRegex(
                module.ProvenanceError,
                "canonical|symlink-free",
            ):
                module.native_decompiler_golden_evidence(
                    arguments,
                    head_commit=run_git(fixture.root, "rev-parse", "HEAD"),
                    tools={
                        "xcode_version": "27.0",
                        "xcode_build": "27A5218g",
                        "swift_compiler_version": "6.4",
                        "swift_target_triple": "arm64-apple-macosx27.0.0",
                    },
                )

    @unittest.skipUnless(
        Path("/tmp").is_symlink()
        and Path("/tmp").resolve() == Path("/private/tmp"),
        "Darwin /tmp alias is unavailable",
    )
    def test_release_accepts_root_owned_darwin_tmp_alias_as_canonical_output(self) -> None:
        module = load_generator_module()
        with tempfile.TemporaryDirectory(dir="/private/tmp") as temporary_directory:
            fixture = ReleaseRepositoryFixture(Path(temporary_directory))
            arguments = fixture.arguments(module)
            relative_root = fixture.root.relative_to("/private/tmp")
            alias_root = Path("/tmp") / relative_root
            alias_arguments = module.ProvenanceArguments(
                **{
                    **arguments.__dict__,
                    "output": alias_root / arguments.output.relative_to(fixture.root),
                    "native_decompiler_golden_result": (
                        alias_root
                        / arguments.native_decompiler_golden_result.relative_to(fixture.root)
                    ),
                }
            )

            app_root, golden = module._derived_embedded_native_decompiler_paths(
                alias_arguments
            )

            self.assertEqual(app_root, arguments.output.parents[2])
            self.assertEqual(golden, arguments.native_decompiler_golden_result)

    @unittest.skipUnless(
        Path("/var").is_symlink()
        and Path("/var").resolve() == Path("/private/var"),
        "Darwin /var alias is unavailable",
    )
    def test_release_accepts_root_owned_darwin_var_alias_as_canonical_output(self) -> None:
        module = load_generator_module()
        canonical_temporary_root = Path(tempfile.gettempdir()).resolve()
        self.assertTrue(canonical_temporary_root.is_relative_to("/private/var"))
        with tempfile.TemporaryDirectory(
            dir=canonical_temporary_root
        ) as temporary_directory:
            fixture = ReleaseRepositoryFixture(Path(temporary_directory))
            arguments = fixture.arguments(module)
            relative_root = fixture.root.relative_to("/private/var")
            alias_root = Path("/var") / relative_root
            alias_arguments = module.ProvenanceArguments(
                **{
                    **arguments.__dict__,
                    "output": alias_root / arguments.output.relative_to(fixture.root),
                    "native_decompiler_golden_result": (
                        alias_root
                        / arguments.native_decompiler_golden_result.relative_to(fixture.root)
                    ),
                }
            )

            app_root, golden = module._derived_embedded_native_decompiler_paths(
                alias_arguments
            )

            self.assertEqual(app_root, arguments.output.parents[2])
            self.assertEqual(golden, arguments.native_decompiler_golden_result)

    def test_release_rejects_unexpected_embedded_service_entries(self) -> None:
        module = load_generator_module()
        relative_directories = (
            "",
            "Contents",
            "Contents/Resources",
            "Contents/MacOS",
            "Contents/_CodeSignature",
        )
        for relative in relative_directories:
            with self.subTest(relative=relative), tempfile.TemporaryDirectory() as directory:
                fixture = ReleaseRepositoryFixture(Path(directory))
                arguments = fixture.arguments(module)
                service_root = fixture.native_decompiler_golden_result.parents[2]
                unexpected = service_root / relative / "unexpected-entry"
                unexpected.write_bytes(b"not part of the sealed service\n")

                with self.assertRaisesRegex(module.ProvenanceError, "unexpected entries"):
                    module.native_decompiler_golden_evidence(
                        arguments,
                        head_commit=run_git(fixture.root, "rev-parse", "HEAD"),
                        tools={
                            "xcode_version": "27.0",
                            "xcode_build": "27A5218g",
                            "swift_compiler_version": "6.4",
                            "swift_target_triple": "arm64-apple-macosx27.0.0",
                        },
                    )

    def test_embedded_snapshot_streams_large_service_files_without_retaining_payloads(self) -> None:
        module = load_generator_module()
        with tempfile.TemporaryDirectory() as temporary_directory:
            fixture = ReleaseRepositoryFixture(Path(temporary_directory))
            fixture.arguments(module)
            snapshot = module._capture_embedded_native_decompiler_snapshot(
                fixture.output.parents[2]
            )

            self.assertRegex(snapshot["executable_digest"], r"^[0-9a-f]{64}$")
            self.assertRegex(snapshot["code_resources_digest"], r"^[0-9a-f]{64}$")
            self.assertNotIn("executable_bytes", snapshot)
            self.assertNotIn("code_resources_bytes", snapshot)
            self.assertLessEqual(len(snapshot["golden_bytes"]), 64 * 1024)
            self.assertLessEqual(len(snapshot["info_bytes"]), 1024 * 1024)
            self.assertLessEqual(
                len(snapshot["manifest_bytes"]),
                module.MAX_NATIVE_MATERIALIZATION_MANIFEST_BYTES,
            )

    def test_embedded_snapshot_allows_unrelated_shared_ancestor_entry_churn(self) -> None:
        module = load_generator_module()
        with tempfile.TemporaryDirectory() as temporary_directory:
            fixture = ReleaseRepositoryFixture(Path(temporary_directory))
            fixture.arguments(module)
            original_open = module.os.open
            churned = False

            def churn_shared_ancestor(path, flags, *args, **kwargs):
                nonlocal churned
                descriptor = original_open(path, flags, *args, **kwargs)
                if path == "MacScope.app" and kwargs.get("dir_fd") is not None and not churned:
                    sibling = fixture.root / ".provenance-ancestry-churn"
                    sibling.write_bytes(b"unrelated sibling activity\n")
                    sibling.unlink()
                    churned = True
                return descriptor

            with mock.patch.object(module.os, "open", side_effect=churn_shared_ancestor):
                snapshot = module._capture_embedded_native_decompiler_snapshot(
                    fixture.output.parents[2]
                )

            self.assertTrue(churned)
            self.assertRegex(snapshot["executable_digest"], r"^[0-9a-f]{64}$")

    def test_release_retains_complete_ancestry_against_concurrent_symlink_swap(self) -> None:
        module = load_generator_module()
        with tempfile.TemporaryDirectory() as temporary_directory:
            fixture = ReleaseRepositoryFixture(Path(temporary_directory))
            arguments = fixture.arguments(module)
            head = run_git(fixture.root, "rev-parse", "HEAD")
            detached_root = fixture.root.with_name(f"{fixture.root.name}-detached")
            original_open = module.os.open
            swapped = False

            def swap_checked_ancestor(path, flags, *args, **kwargs):
                nonlocal swapped
                descriptor = original_open(path, flags, *args, **kwargs)
                if path == "Build" and kwargs.get("dir_fd") is not None and not swapped:
                    fixture.root.rename(detached_root)
                    fixture.root.symlink_to(detached_root, target_is_directory=True)
                    swapped = True
                return descriptor

            try:
                with mock.patch.object(module.os, "open", side_effect=swap_checked_ancestor):
                    with self.assertRaisesRegex(
                        module.ProvenanceError,
                        "ancestry|path graph|ordinary directory",
                    ):
                        module.native_decompiler_golden_evidence(
                            arguments,
                            head_commit=head,
                            tools={
                                "xcode_version": "27.0",
                                "xcode_build": "27A5218g",
                                "swift_compiler_version": "6.4",
                                "swift_target_triple": "arm64-apple-macosx27.0.0",
                            },
                        )
                self.assertTrue(swapped)
            finally:
                if fixture.root.is_symlink():
                    fixture.root.unlink()
                    detached_root.rename(fixture.root)

    def test_embedded_snapshot_rejects_entry_depth_and_path_amplification(self) -> None:
        module = load_generator_module()
        cases = ("entries", "depth", "path-bytes")
        for case in cases:
            with self.subTest(case=case), tempfile.TemporaryDirectory() as directory:
                fixture = ReleaseRepositoryFixture(Path(directory))
                fixture.arguments(module)
                package_root = (
                    fixture.native_decompiler_golden_result.parent
                    / "NativeDecompilerPackage/package"
                )
                patches = []
                expected = ""
                if case == "entries":
                    for index in range(32):
                        (package_root / f"empty-{index:02d}").mkdir()
                    patches.append(
                        mock.patch.object(module, "MAX_PROVENANCE_TREE_ENTRIES", 24)
                    )
                    expected = "entry bound"
                elif case == "depth":
                    nested = package_root
                    for component in ("one", "two", "three", "four"):
                        nested = nested / component
                        nested.mkdir()
                    patches.append(
                        mock.patch.object(module, "MAX_PROVENANCE_TREE_DEPTH", 3)
                    )
                    expected = "traversal depth"
                else:
                    (package_root / "retained-path-amplifier").mkdir()
                    patches.append(
                        mock.patch.object(module, "MAX_PROVENANCE_TREE_PATH_BYTES", 32)
                    )
                    expected = "path-memory bound"

                with patches[0], self.assertRaisesRegex(module.ProvenanceError, expected):
                    module._capture_embedded_native_decompiler_snapshot(
                        fixture.output.parents[2]
                    )

    def test_release_rejects_mutation_between_service_snapshot_and_final_revalidation(self) -> None:
        module = load_generator_module()
        with tempfile.TemporaryDirectory() as temporary_directory:
            fixture = ReleaseRepositoryFixture(Path(temporary_directory))
            arguments = fixture.arguments(module)
            original_capture = module._capture_embedded_native_decompiler_snapshot
            captures = 0

            def mutate_between_captures(*capture_arguments, **capture_keywords):
                nonlocal captures
                snapshot = original_capture(*capture_arguments, **capture_keywords)
                captures += 1
                if captures == 1:
                    info = (
                        fixture.native_decompiler_golden_result.parents[2]
                        / "Contents/Info.plist"
                    )
                    info.write_bytes(b"x" * info.stat().st_size)
                return snapshot

            with mock.patch.object(
                module,
                "_capture_embedded_native_decompiler_snapshot",
                side_effect=mutate_between_captures,
            ), self.assertRaisesRegex(module.ProvenanceError, "changed|snapshot"):
                module.native_decompiler_golden_evidence(
                    arguments,
                    head_commit=run_git(fixture.root, "rev-parse", "HEAD"),
                    tools={
                        "xcode_version": "27.0",
                        "xcode_build": "27A5218g",
                        "swift_compiler_version": "6.4",
                        "swift_target_triple": "arm64-apple-macosx27.0.0",
                    },
                )

    def test_embedded_provenance_keeps_service_and_package_authority(self) -> None:
        module = load_generator_module()
        self.assertTrue(hasattr(module, "validate_golden_payload"), "missing shared golden validator")
        for target in ("service", "package"):
            with self.subTest(target=target), tempfile.TemporaryDirectory() as directory:
                fixture = ReleaseRepositoryFixture(Path(directory))
                arguments = fixture.arguments(module)
                validate = module.validate_golden_payload

                def mutate_after_payload_validation(payload, *, expected_identity):
                    result = validate(payload, expected_identity=expected_identity)
                    if target == "service":
                        path = fixture.native_decompiler_golden_result.parents[2] / "Contents/MacOS/NativeDecompilerXPCService"
                    else:
                        path = fixture.native_decompiler_golden_result.parent / "NativeDecompilerPackage/package/share/package-note.txt"
                    path.write_bytes(b"mutated-after-valid-payload\n")
                    return result

                with mock.patch.object(module, "validate_golden_payload", side_effect=mutate_after_payload_validation):
                    with self.assertRaisesRegex(module.ProvenanceError, "changed after its stable snapshot"):
                        module.native_decompiler_golden_evidence(arguments, tools={
                            "xcode_version": "27.0", "xcode_build": "27A5218g",
                            "swift_compiler_version": "6.4", "swift_target_triple": "arm64-apple-macosx27.0.0",
                        })

    def test_release_rejects_embedded_package_mutation_after_golden(self) -> None:
        module = load_generator_module()
        mutations = {
            "manifest": (
                lambda fixture: (
                    fixture.native_decompiler_golden_result.parent
                    / "NativeDecompilerPackage/MATERIALIZATION.json"
                ).write_bytes(b"{}\n"),
                "embedded native decompiler materialization differs from the strict "
                "verified SLEIGH input",
            ),
            "noncritical-tree-file": (
                lambda fixture: (
                    fixture.native_decompiler_golden_result.parent
                    / "NativeDecompilerPackage/package/share/package-note.txt"
                ).write_bytes(b"post-golden-noncritical-substitution\n"),
                "embedded native decompiler package tree differs from its manifest",
            ),
            "archive": (
                lambda fixture: (
                    fixture.native_decompiler_golden_result.parent
                    / "NativeDecompilerPackage/package/lib/libdecomp.a"
                ).write_bytes(b"post-golden-archive-substitution\n"),
                "embedded native decompiler package tree differs from its manifest",
            ),
        }
        for name, (mutate, expected_failure) in mutations.items():
            with self.subTest(name=name), tempfile.TemporaryDirectory() as temporary_directory:
                fixture = ReleaseRepositoryFixture(Path(temporary_directory))
                arguments = fixture.arguments(module)
                mutate(fixture)

                with self.assertRaisesRegex(
                    module.ProvenanceError,
                    rf"^{re.escape(expected_failure)}$",
                ):
                    module.native_decompiler_golden_evidence(
                        arguments,
                        head_commit=run_git(fixture.root, "rev-parse", "HEAD"),
                        tools={
                            "xcode_version": "27.0",
                            "xcode_build": "27A5218g",
                            "swift_compiler_version": "6.4",
                            "swift_target_triple": "arm64-apple-macosx27.0.0",
                        },
                    )

    def test_release_inventories_the_final_embedded_service_and_rejects_mutation(self) -> None:
        module = load_generator_module()
        mutations = {
            "info": lambda fixture: (
                fixture.native_decompiler_golden_result.parents[2] / "Contents/Info.plist"
            ).write_bytes(b"not-a-plist\n"),
            "executable": lambda fixture: (
                fixture.native_decompiler_golden_result.parents[2]
                / "Contents/MacOS/NativeDecompilerXPCService"
            ).unlink(),
            "code-resources": lambda fixture: (
                fixture.native_decompiler_golden_result.parents[2]
                / "Contents/_CodeSignature/CodeResources"
            ).unlink(),
        }
        for name, mutate in mutations.items():
            with self.subTest(name=name), tempfile.TemporaryDirectory() as temporary_directory:
                fixture = ReleaseRepositoryFixture(Path(temporary_directory))
                arguments = fixture.arguments(module)
                mutate(fixture)

                with self.assertRaises((module.ProvenanceError, OSError)):
                    module.native_decompiler_golden_evidence(
                        arguments,
                        head_commit=run_git(fixture.root, "rev-parse", "HEAD"),
                        tools={
                            "xcode_version": "27.0",
                            "xcode_build": "27A5218g",
                            "swift_compiler_version": "6.4",
                            "swift_target_triple": "arm64-apple-macosx27.0.0",
                        },
                    )

    def test_service_inventory_rejects_info_mutation_after_identity_parse(self) -> None:
        module = load_generator_module()
        with tempfile.TemporaryDirectory() as temporary_directory:
            fixture = ReleaseRepositoryFixture(Path(temporary_directory))
            fixture.arguments(module)
            service_root = fixture.native_decompiler_golden_result.parents[2]
            info_path = service_root / "Contents/Info.plist"
            original_sha256_file = module.sha256_file

            def mutate_info_after_executable_hash(path: Path):
                result = original_sha256_file(path)
                if path.name == "NativeDecompilerXPCService":
                    info_path.write_bytes(b"x" * info_path.stat().st_size)
                return result

            with mock.patch.object(
                module,
                "sha256_file",
                side_effect=mutate_info_after_executable_hash,
            ), self.assertRaisesRegex(module.ProvenanceError, "Info.plist changed"):
                module.embedded_native_decompiler_service_evidence(
                    fixture.native_decompiler_golden_result
                )

    def test_release_rejects_golden_package_digest_mismatch(self) -> None:
        module = load_generator_module()
        with tempfile.TemporaryDirectory() as temporary_directory:
            fixture = ReleaseRepositoryFixture(Path(temporary_directory))
            arguments = fixture.arguments(module)
            mismatched = fixture.golden_result_payload()
            mismatched["materializationTreeSHA256"] = "f" * 64
            fixture.write_golden_result(mismatched)

            with self.assertRaisesRegex(
                module.ProvenanceError,
                "materializationTreeSHA256 differs from the golden result",
            ):
                module.native_decompiler_golden_evidence(
                    arguments,
                    head_commit=run_git(fixture.root, "rev-parse", "HEAD"),
                    tools={
                        "xcode_version": "27.0",
                        "xcode_build": "27A5218g",
                        "swift_compiler_version": "6.4",
                        "swift_target_triple": "arm64-apple-macosx27.0.0",
                    },
                )

    def test_release_rejects_missing_or_malformed_native_decompiler_evidence(self) -> None:
        module = load_generator_module()
        with tempfile.TemporaryDirectory() as temporary_directory:
            fixture = ReleaseRepositoryFixture(Path(temporary_directory))
            arguments = fixture.arguments(module)
            omitted = module.ProvenanceArguments(
                **{**arguments.__dict__, "native_decompiler_golden_result": None}
            )
            with self.assertRaisesRegex(module.ProvenanceError, "requires the embedded"):
                module.native_decompiler_golden_evidence(
                    omitted,
                    head_commit=run_git(fixture.root, "rev-parse", "HEAD"),
                    tools={
                        "xcode_version": "27.0",
                        "xcode_build": "27A5218g",
                        "swift_compiler_version": "6.4",
                        "swift_target_triple": "arm64-apple-macosx27.0.0",
                    },
                )
            fixture.native_decompiler_golden_result.unlink()
            with self.assertRaisesRegex(
                module.ProvenanceError,
                "missing or inaccessible|unexpected entries",
            ):
                module.native_decompiler_golden_evidence(
                    arguments,
                    head_commit=run_git(fixture.root, "rev-parse", "HEAD"),
                    tools={
                        "xcode_version": "27.0",
                        "xcode_build": "27A5218g",
                        "swift_compiler_version": "6.4",
                        "swift_target_triple": "arm64-apple-macosx27.0.0",
                    },
                )
            fixture.native_decompiler_golden_result.write_bytes(b"{not-json}\n")
            with self.assertRaisesRegex(module.ProvenanceError, "malformed"):
                module.native_decompiler_golden_evidence(
                    arguments,
                    head_commit=run_git(fixture.root, "rev-parse", "HEAD"),
                    tools={
                        "xcode_version": "27.0",
                        "xcode_build": "27A5218g",
                        "swift_compiler_version": "6.4",
                        "swift_target_triple": "arm64-apple-macosx27.0.0",
                    },
                )

    def test_release_rejects_application_substitution_during_final_publication(self) -> None:
        module = load_generator_module()
        with tempfile.TemporaryDirectory() as temporary_directory:
            fixture = ReleaseRepositoryFixture(Path(temporary_directory))
            arguments = fixture.arguments(module)
            application = fixture.output.parents[2]
            detached_application = fixture.root / "detached-MacScope.app"
            original_replace = module.os.replace
            substituted = False
            replace_calls = 0

            def substitute_at_publication(source, destination, *args, **kwargs):
                nonlocal replace_calls, substituted
                replace_calls += 1
                if kwargs.get("src_dir_fd") is not None and not substituted:
                    application.rename(detached_application)
                    application.mkdir()
                    (application / "replacement-marker").write_text(
                        "replacement application\n",
                        encoding="utf-8",
                    )
                    substituted = True
                return original_replace(source, destination, *args, **kwargs)

            with mock.patch.object(
                module.os,
                "replace",
                side_effect=substitute_at_publication,
            ), self.assertRaisesRegex(
                module.ProvenanceError,
                (
                    r"^application Contents cannot be opened safely: \[Errno 2\] "
                    r"No such file or directory: 'Contents'$"
                ),
            ) as raised:
                module.generate(arguments, tool_runner=FixtureToolRunner())

            self.assertTrue(
                substituted,
                "publication substitution did not run; "
                f"raised={raised.exception!r}; replace_calls={replace_calls}",
            )
            self.assertTrue((application / "replacement-marker").is_file())
            self.assertFalse(fixture.output.exists())

    def test_release_failure_cleanup_preserves_substituted_temporary_name(self) -> None:
        module = load_generator_module()
        with tempfile.TemporaryDirectory() as temporary_directory:
            fixture = ReleaseRepositoryFixture(Path(temporary_directory))
            arguments = fixture.arguments(module)
            detached_owned = fixture.output.parent / "detached-owned-temporary"
            replacement = None
            substituted = False

            def substitute_before_forced_failure(_app_root, _snapshot):
                nonlocal replacement, substituted
                prefix = f".{fixture.output.name}."
                candidates = tuple(
                    path
                    for path in fixture.output.parent.iterdir()
                    if path.name.startswith(prefix)
                )
                self.assertEqual(len(candidates), 1)
                candidates[0].rename(detached_owned)
                candidates[0].write_bytes(b"foreign replacement residue\n")
                replacement = candidates[0]
                substituted = True
                raise module.ProvenanceError("forced publication failure after substitution")

            with mock.patch.object(
                module,
                "_revalidate_embedded_snapshot_lease",
                side_effect=substitute_before_forced_failure,
            ), self.assertRaisesRegex(
                module.ProvenanceError,
                "forced publication failure after substitution",
            ):
                module.generate(arguments, tool_runner=FixtureToolRunner())

            self.assertTrue(substituted)
            self.assertIsNotNone(replacement)
            self.assertTrue(detached_owned.is_file())
            self.assertGreater(detached_owned.stat().st_size, 0)
            self.assertTrue(replacement.is_file())
            self.assertEqual(replacement.read_bytes(), b"foreign replacement residue\n")
            self.assertFalse(fixture.output.exists())

    def test_release_rejects_golden_key_drift_noncanonical_json_and_identity_mismatch(self) -> None:
        module = load_generator_module()
        with tempfile.TemporaryDirectory() as temporary_directory:
            fixture = ReleaseRepositoryFixture(Path(temporary_directory))
            arguments = fixture.arguments(module)
            head = run_git(fixture.root, "rev-parse", "HEAD")
            tools = {
                "xcode_version": "27.0",
                "xcode_build": "27A5218g",
                "swift_compiler_version": "6.4",
                "swift_target_triple": "arm64-apple-macosx27.0.0",
            }

            extra_key = fixture.golden_result_payload()
            extra_key["localPath"] = "/Users/example/package"
            fixture.write_golden_result(extra_key)
            with self.assertRaisesRegex(module.ProvenanceError, "unsupported fields"):
                module.native_decompiler_golden_evidence(
                    arguments, head_commit=head, tools=tools
                )

            fixture.write_golden_result(canonical=False)
            with self.assertRaisesRegex(module.ProvenanceError, "canonical JSON"):
                module.native_decompiler_golden_evidence(
                    arguments, head_commit=head, tools=tools
                )

            wrong_identity = fixture.golden_result_payload()
            wrong_identity["wrapperGitRevision"] = "f" * 40
            fixture.write_golden_result(wrong_identity)
            with self.assertRaisesRegex(module.ProvenanceError, "wrapperGitRevision differs"):
                module.native_decompiler_golden_evidence(
                    arguments, head_commit=head, tools=tools
                )

            invalid_digest = fixture.golden_result_payload()
            invalid_digest["contractArchiveSHA256"] = "not-a-digest"
            fixture.write_golden_result(invalid_digest)
            with self.assertRaisesRegex(module.ProvenanceError, "invalid contractArchiveSHA256"):
                module.native_decompiler_golden_evidence(
                    arguments, head_commit=head, tools=tools
                )

    def test_golden_wrapper_identity_accepts_dcp05c_and_rejects_stale_dcp03b5(self) -> None:
        module = load_generator_module()
        with tempfile.TemporaryDirectory() as temporary_directory:
            fixture = ReleaseRepositoryFixture(Path(temporary_directory))
            arguments = fixture.arguments(module)
            tools = {
                "xcode_version": "27.0",
                "xcode_build": "27A5218g",
                "swift_compiler_version": "6.4",
                "swift_target_triple": "arm64-apple-macosx27.0.0",
            }

            current = module.native_decompiler_golden_evidence(
                arguments,
                tools=tools,
            )
            self.assertEqual(
                current["native_decompiler_golden_result"]["wrapperVersion"],
                "dcp05c-v1",
            )

            stale = fixture.golden_result_payload()
            stale["wrapperVersion"] = "dcp03b5-v1"
            fixture.write_golden_result(stale)
            with self.assertRaisesRegex(module.ProvenanceError, "wrapperVersion differs"):
                module.native_decompiler_golden_evidence(
                    arguments,
                    tools=tools,
                )

    def test_manifest_is_length_framed_sorted_path_plus_raw_sha256(self) -> None:
        module = load_generator_module()
        entries = {
            "z.swift": bytes.fromhex("ff" * 32),
            "a.swift": bytes.fromhex("00" * 32),
        }
        expected = hashlib.sha256(
            (len(b"a.swift")).to_bytes(8, "big")
            + b"a.swift"
            + bytes.fromhex("00" * 32)
            + (len(b"z.swift")).to_bytes(8, "big")
            + b"z.swift"
            + bytes.fromhex("ff" * 32)
        ).hexdigest()

        self.assertEqual(module.selected_inputs_digest(entries), expected)

    def test_release_rejects_dirty_or_global_untracked_repository(self) -> None:
        module = load_generator_module()
        mutations = {
            "modified": lambda fixture: (fixture.root / "MacScope/App/Main.swift").write_text(
                "struct Changed {}\n", encoding="utf-8"
            ),
            "untracked": lambda fixture: (fixture.root / "Notes.txt").write_text(
                "not tracked\n", encoding="utf-8"
            ),
        }
        for name, mutation in mutations.items():
            with self.subTest(name=name), tempfile.TemporaryDirectory() as temporary_directory:
                fixture = ReleaseRepositoryFixture(Path(temporary_directory))
                mutation(fixture)
                with self.assertRaisesRegex(module.ProvenanceError, "clean|untracked"):
                    module.generate(fixture.arguments(module), tool_runner=FixtureToolRunner())

    def test_release_rejects_ignored_file_selected_by_source_glob(self) -> None:
        module = load_generator_module()
        with tempfile.TemporaryDirectory() as temporary_directory:
            fixture = ReleaseRepositoryFixture(Path(temporary_directory))
            ignored = fixture.root / "MacScope/App/IgnoredGenerated.swift"
            ignored.write_text("struct Ignored {}\n", encoding="utf-8")
            self.assertEqual(run_git(fixture.root, "status", "--porcelain"), "")

            with self.assertRaisesRegex(module.ProvenanceError, "ordinary HEAD blob"):
                module.generate(fixture.arguments(module), tool_runner=FixtureToolRunner())

    def test_release_ignores_transient_python_bytecode_in_governed_directory(self) -> None:
        module = load_generator_module()
        with tempfile.TemporaryDirectory() as temporary_directory:
            fixture = ReleaseRepositoryFixture(Path(temporary_directory))
            gitignore = fixture.root / ".gitignore"
            gitignore.write_text(
                gitignore.read_text(encoding="utf-8")
                + "**/__pycache__/\n*.pyc\n*.pyo\n",
                encoding="utf-8",
            )
            run_git(fixture.root, "add", ".gitignore")
            run_git(fixture.root, "commit", "-qm", "ignore interpreter caches")

            cache = fixture.root / "ThirdParty/FixtureTool/__pycache__"
            cache.mkdir()
            (cache / "sleigh_package.cpython-314.pyc").write_bytes(b"transient bytecode")
            (fixture.root / "ThirdParty/FixtureTool/temporary.pyo").write_bytes(
                b"optimized transient bytecode"
            )
            tracked_source = fixture.root / "MacScope/App/__pycache__/Injected.swift"
            tracked_source.parent.mkdir()
            tracked_source.write_text("struct TrackedCacheNamedSource {}\n", encoding="utf-8")
            tracked_bytecode = cache / "tracked.pyc"
            tracked_bytecode.write_bytes(b"tracked bytecode fixture")
            run_git(
                fixture.root,
                "add",
                "-f",
                "MacScope/App/__pycache__/Injected.swift",
                "ThirdParty/FixtureTool/__pycache__/tracked.pyc",
            )
            run_git(fixture.root, "commit", "-qm", "track cache-named build inputs")
            self.assertEqual(run_git(fixture.root, "status", "--porcelain"), "")

            selected = module.selected_source_paths(
                fixture.root,
                fixture.project_yml,
                fixture.project_yml.read_text(encoding="utf-8"),
            )
            payload = module.generate(
                fixture.arguments(module),
                tool_runner=FixtureToolRunner(),
            )

            self.assertNotIn(
                "ThirdParty/FixtureTool/__pycache__/sleigh_package.cpython-314.pyc",
                selected,
            )
            self.assertNotIn("ThirdParty/FixtureTool/temporary.pyo", selected)
            self.assertIn("MacScope/App/__pycache__/Injected.swift", selected)
            self.assertIn("ThirdParty/FixtureTool/__pycache__/tracked.pyc", selected)
            self.assertTrue(payload["qualification_eligible"])

    def test_release_ignores_untracked_finder_metadata_but_preserves_tracked_inputs(self) -> None:
        module = load_generator_module()
        with tempfile.TemporaryDirectory() as temporary_directory:
            fixture = ReleaseRepositoryFixture(Path(temporary_directory))
            gitignore = fixture.root / ".gitignore"
            gitignore.write_text(gitignore.read_text(encoding="utf-8") + ".DS_Store\n", encoding="utf-8")
            run_git(fixture.root, "add", ".gitignore")
            run_git(fixture.root, "commit", "-qm", "ignore Finder metadata")
            metadata = fixture.root / "ThirdParty/FixtureTool/.DS_Store"
            metadata.write_bytes(b"Finder folder display metadata")
            selected = module.selected_source_paths(fixture.root, fixture.project_yml,
                fixture.project_yml.read_text(encoding="utf-8"))
            self.assertNotIn("ThirdParty/FixtureTool/.DS_Store", selected)
            payload = module.generate(fixture.arguments(module), tool_runner=FixtureToolRunner())
            self.assertTrue(payload["qualification_eligible"])
            run_git(fixture.root, "add", "-f", "ThirdParty/FixtureTool/.DS_Store")
            run_git(fixture.root, "commit", "-qm", "track explicit metadata fixture")
            selected = module.selected_source_paths(fixture.root, fixture.project_yml,
                fixture.project_yml.read_text(encoding="utf-8"))
            self.assertIn("ThirdParty/FixtureTool/.DS_Store", selected)

    def test_release_applies_source_excludes_before_ignored_input_check(self) -> None:
        module = load_generator_module()
        with tempfile.TemporaryDirectory() as temporary_directory:
            fixture = ReleaseRepositoryFixture(Path(temporary_directory))
            ignored = (
                fixture.root
                / "MacScope/Services/Phase2/IgnoredExcluded.swift"
            )
            ignored.write_text("struct IntentionallyExcluded {}\n", encoding="utf-8")
            self.assertEqual(run_git(fixture.root, "status", "--porcelain"), "")

            payload = module.generate(
                fixture.arguments(module),
                tool_runner=FixtureToolRunner(),
            )

            self.assertTrue(payload["qualification_eligible"])

    def test_release_rejects_selected_symlink_even_when_git_tracks_it(self) -> None:
        module = load_generator_module()
        with tempfile.TemporaryDirectory() as temporary_directory:
            fixture = ReleaseRepositoryFixture(Path(temporary_directory))
            link = fixture.root / "MacScope/App/Linked.swift"
            link.symlink_to("Main.swift")
            run_git(fixture.root, "add", "MacScope/App/Linked.swift")
            run_git(fixture.root, "commit", "-qm", "track symlink")
            self.assertTrue(stat.S_ISLNK(link.lstat().st_mode))

            with self.assertRaisesRegex(module.ProvenanceError, "regular file"):
                module.generate(fixture.arguments(module), tool_runner=FixtureToolRunner())

    def test_release_rejects_wrong_build_identity_before_emitting_output(self) -> None:
        module = load_generator_module()
        with tempfile.TemporaryDirectory() as temporary_directory:
            fixture = ReleaseRepositoryFixture(Path(temporary_directory))
            arguments = fixture.arguments(module)
            arguments = module.ProvenanceArguments(
                **{**arguments.__dict__, "architectures": "arm64 x86_64"}
            )

            with self.assertRaisesRegex(module.ProvenanceError, "arm64"):
                module.generate(arguments, tool_runner=FixtureToolRunner())

            self.assertFalse(fixture.output.exists())

    def test_fresh_project_validation_stages_siblings_with_shared_parent(self) -> None:
        module = load_generator_module()
        with tempfile.TemporaryDirectory() as temporary_directory:
            fixture = ReleaseRepositoryFixture(Path(temporary_directory))
            fixture.project_yml.write_text(
                "name: MacScope\npackages:\n  Lumen:\n    path: ../ThirdParty/Lumen\n"
                "  RecoveryKit:\n    path: ../Packages/RecoveryKit\n"
                "targets:\n  SwiftAssemblyVendor:\n    type: library.static\n"
                "    platform: macOS\n    sources:\n"
                "      - path: ../ThirdParty/SwiftAssemblyVendor/Sources\n",
                encoding="utf-8",
            )
            source_files = {
                "ThirdParty/SwiftAssemblyVendor/Sources/ARM64/ARM64Assembler.swift":
                    b"public struct ARM64Assembler {}\n",
                "ThirdParty/Lumen/Package.swift": b"// fixture package manifest\n",
                "Packages/RecoveryKit/Package.swift": b"// fixture recovery package\n",
                "Packages/RecoveryKit/Sources/RecoveryKit/Identity.swift":
                    b"public struct Identity {}\n",
            }
            for relative, contents in source_files.items():
                source = fixture.root / relative
                source.parent.mkdir(parents=True, exist_ok=True)
                source.write_bytes(contents)
            runner = FixtureToolRunner()

            def inspect_staging(command, cwd):
                if Path(command[0]).name == "xcodegen" and command[1] == "generate":
                    for relative, contents in source_files.items():
                        staged = cwd.parent / relative
                        self.assertEqual(staged.read_bytes(), contents)
                        self.assertEqual(staged.resolve(), (fixture.root / relative).resolve())
                return runner(command, cwd)

            module.require_fresh_generated_project(
                fixture.arguments(module), fixture.root, inspect_staging,
            )
            for relative, contents in source_files.items():
                self.assertEqual((fixture.root / relative).read_bytes(), contents)

    def test_fresh_project_validation_rejects_symlinked_recovery_package(self) -> None:
        module = load_generator_module()
        with tempfile.TemporaryDirectory() as temporary_directory:
            fixture = ReleaseRepositoryFixture(Path(temporary_directory))
            fixture.project_yml.write_text(
                "name: MacScope\npackages:\n  RecoveryKit:\n"
                "    path: ../Packages/RecoveryKit\n",
                encoding="utf-8",
            )
            package = fixture.root / "Packages/RecoveryKit"
            package.parent.mkdir()
            source = fixture.root / "RecoverySource"
            source.mkdir()
            (source / "Package.swift").write_text("// fixture recovery package\n")
            package.symlink_to(source, target_is_directory=True)
            runner = FixtureToolRunner()
            with self.assertRaisesRegex(
                module.ProvenanceError,
                "Packages/RecoveryKit must be an ordinary directory",
            ):
                module.require_fresh_generated_project(
                    fixture.arguments(module), fixture.root, runner,
                )
            self.assertEqual(runner.calls, [])

    def test_release_rejects_generated_project_byte_drift(self) -> None:
        module = load_generator_module()
        with tempfile.TemporaryDirectory() as temporary_directory:
            fixture = ReleaseRepositoryFixture(Path(temporary_directory))
            (fixture.xcodeproj / "project.xcproj").write_text(
                "// stale locally altered source membership\n",
                encoding="utf-8",
            )
            self.assertEqual(run_git(fixture.root, "status", "--porcelain"), "")

            with self.assertRaisesRegex(module.ProvenanceError, "differs from fresh"):
                module.generate(
                    fixture.arguments(module),
                    tool_runner=FixtureToolRunner(),
                )

    @unittest.skipUnless(shutil.which("xcodegen"), "xcodegen is required for this integration test")
    def test_fresh_project_validation_matches_real_bootstrap_generation_out_of_tree(self) -> None:
        module = load_generator_module()
        with tempfile.TemporaryDirectory() as temporary_directory:
            fixture = ReleaseRepositoryFixture(Path(temporary_directory))
            fixture.project_yml.write_text(
                """\
name: MacScope
configFiles:
  Debug: DependencyRoots.xcconfig
  Release: DependencyRoots.xcconfig
targets:
  MacScopeApp:
    type: application
    platform: macOS
    sources:
      - path: App
""",
                encoding="utf-8",
            )
            (fixture.project_yml.parent / "DependencyRoots.xcconfig").write_text(
                "MACSCOPE_GHOSTTY_SOURCE_DIR =\n",
                encoding="utf-8",
            )
            (fixture.xcodeproj / "project.xcproj").unlink()
            bootstrap = module.run_tool(
                ["xcodegen", "generate"],
                fixture.project_yml.parent,
            )
            self.assertEqual(bootstrap.returncode, 0, bootstrap.stderr)
            conversion = module.run_tool(
                ["/usr/bin/xcrun", "xcodebuild", "-convert-project", "Xcode Project",
                 "-project", str(fixture.xcodeproj)], fixture.project_yml.parent,
            )
            self.assertEqual(conversion.returncode, 0, conversion.stderr)

            with mock.patch.dict(os.environ, {"MACSCOPE_XCODEGEN": shutil.which("xcodegen")}):
                module.require_fresh_generated_project(
                    fixture.arguments(module),
                    fixture.root,
                    module.run_tool,
                )

    @unittest.skipUnless(shutil.which("xcodegen"), "xcodegen is required for this integration test")
    def test_fresh_project_validation_includes_governed_repository_sibling_sources(self) -> None:
        module = load_generator_module()
        with tempfile.TemporaryDirectory() as temporary_directory:
            fixture = ReleaseRepositoryFixture(Path(temporary_directory))
            fixture.project_yml.write_text(
                """\
name: MacScope
targets:
  SwiftAssemblyVendor:
    type: library.static
    platform: macOS
    sources:
      - path: ../ThirdParty/SwiftAssemblyVendor/Sources
  MacScopeApp:
    type: application
    platform: macOS
    sources:
      - path: App
    dependencies:
      - target: SwiftAssemblyVendor
""",
                encoding="utf-8",
            )
            vendor_source = (
                fixture.root
                / "ThirdParty/SwiftAssemblyVendor/Sources/ARM64/ARM64Assembler.swift"
            )
            vendor_source.parent.mkdir(parents=True)
            vendor_source.write_text("public struct ARM64Assembler {}\n", encoding="utf-8")
            (fixture.xcodeproj / "project.xcproj").unlink()
            bootstrap = module.run_tool(
                ["xcodegen", "generate"],
                fixture.project_yml.parent,
            )
            self.assertEqual(bootstrap.returncode, 0, bootstrap.stderr)
            conversion = module.run_tool(
                ["/usr/bin/xcrun", "xcodebuild", "-convert-project", "Xcode Project",
                 "-project", str(fixture.xcodeproj)], fixture.project_yml.parent,
            )
            self.assertEqual(conversion.returncode, 0, conversion.stderr)

            with mock.patch.dict(os.environ, {"MACSCOPE_XCODEGEN": shutil.which("xcodegen")}):
                module.require_fresh_generated_project(
                    fixture.arguments(module),
                    fixture.root,
                    module.run_tool,
                )

    def test_fresh_project_validation_rejects_symlinked_project_inputs(self) -> None:
        module = load_generator_module()
        cases = ("project_yml", "xcodeproj", "project_pbxproj")
        for case in cases:
            with self.subTest(case=case), tempfile.TemporaryDirectory() as directory:
                fixture = ReleaseRepositoryFixture(Path(directory))
                if case == "project_yml":
                    external_spec = fixture.root / "External/project.yml"
                    external_spec.parent.mkdir()
                    external_spec.write_bytes(fixture.project_yml.read_bytes())
                    fixture.project_yml.unlink()
                    fixture.project_yml.symlink_to(external_spec)
                elif case == "xcodeproj":
                    relocated_project = fixture.root / "Relocated.xcodeproj"
                    fixture.xcodeproj.rename(relocated_project)
                    fixture.xcodeproj.symlink_to(
                        relocated_project,
                        target_is_directory=True,
                    )
                else:
                    project_pbx = fixture.xcodeproj / "project.xcproj"
                    relocated_pbx = fixture.xcodeproj / "relocated.pbxproj"
                    project_pbx.rename(relocated_pbx)
                    project_pbx.symlink_to(relocated_pbx.name)

                with self.assertRaisesRegex(module.ProvenanceError, "regular|symlink"):
                    module.require_fresh_generated_project(
                        fixture.arguments(module),
                        fixture.root,
                        FixtureToolRunner(),
                    )

    def test_release_rejects_mismatched_sdk_tuple_or_custom_swift_toolchain(self) -> None:
        module = load_generator_module()
        with tempfile.TemporaryDirectory() as temporary_directory:
            fixture = ReleaseRepositoryFixture(Path(temporary_directory))
            base = fixture.arguments(module)
            mismatched_sdk = module.ProvenanceArguments(
                **{**base.__dict__, "sdk_name": "macosx27.1"}
            )
            with self.assertRaisesRegex(module.ProvenanceError, "SDK|sdk"):
                module.generate(mismatched_sdk, tool_runner=FixtureToolRunner())

        with tempfile.TemporaryDirectory() as temporary_directory:
            fixture = ReleaseRepositoryFixture(Path(temporary_directory))
            custom_swift = fixture.root / "CustomToolchain/usr/bin/swiftc"
            custom_swift.parent.mkdir(parents=True)
            custom_swift.write_text("custom swift\n", encoding="utf-8")
            run_git(fixture.root, "add", "CustomToolchain/usr/bin/swiftc")
            run_git(fixture.root, "commit", "-qm", "custom tool fixture")
            base = fixture.arguments(module)
            custom_toolchain = module.ProvenanceArguments(
                **{**base.__dict__, "swift_executable": custom_swift}
            )
            with self.assertRaisesRegex(module.ProvenanceError, "DEVELOPER_DIR"):
                module.generate(custom_toolchain, tool_runner=FixtureToolRunner())

    def test_toolchain_accepts_current_macos_27_minor_host_triples_only(self) -> None:
        module = load_generator_module()

        class TargetRunner(FixtureToolRunner):
            def __init__(self, target: str) -> None:
                super().__init__()
                self.target = target

            def __call__(self, command, cwd):
                result = super().__call__(command, cwd)
                return subprocess.CompletedProcess(
                    result.args, result.returncode,
                    result.stdout.replace("arm64-apple-macosx27.0.0", self.target),
                    result.stderr,
                )

        with tempfile.TemporaryDirectory() as directory:
            fixture = ReleaseRepositoryFixture(Path(directory))
            arguments = fixture.arguments(module)
            scalars = {("options", "minimumXcodeGenVersion"): "2.45.4"}
            for target in (
                "arm64-apple-macosx27.0", "arm64-apple-macosx27.0.0",
                "arm64-apple-macosx27.2", "arm64-apple-macosx27.2.0",
                "arm64-apple-macosx27.2.1",
            ):
                with self.subTest(target=target):
                    evidence = module.toolchain_evidence(
                        arguments, fixture.root, scalars, TargetRunner(target)
                    )
                    self.assertEqual(evidence["swift_target_triple"], target)
            for target in (
                "x86_64-apple-macosx27.2.0", "arm64-apple-macosx26.2.0",
                "arm64-apple-macosx28.0.0", "arm64-apple-ios27.2.0",
                "arm64-apple-macosx27", "arm64-apple-macosx27.2.0.1",
                "arm64-apple-macosx27.2.0-extra",
            ):
                with self.subTest(target=target):
                    with self.assertRaisesRegex(module.ProvenanceError, "toolchain"):
                        module.toolchain_evidence(
                            arguments, fixture.root, scalars, TargetRunner(target)
                        )

    def test_release_accepts_declared_xcode_swiftc_symlink_and_rejects_alias_or_escape(self) -> None:
        module = load_generator_module()
        with tempfile.TemporaryDirectory() as temporary_directory:
            fixture = ReleaseRepositoryFixture(Path(temporary_directory))
            swift_frontend = fixture.swift_executable.with_name("swift-frontend")
            fixture.swift_executable.rename(swift_frontend)
            fixture.swift_executable.symlink_to(swift_frontend.name)
            run_git(fixture.root, "add", "-A")
            run_git(fixture.root, "commit", "-qm", "swift symlink fixture")

            runner = FixtureToolRunner()
            module.generate(fixture.arguments(module), tool_runner=runner)
            self.assertIn(
                (str(swift_frontend.resolve()), "--version"),
                runner.calls,
            )

            direct_frontend = module.ProvenanceArguments(
                **{
                    **fixture.arguments(module).__dict__,
                    "swift_executable": swift_frontend,
                }
            )
            with self.assertRaisesRegex(module.ProvenanceError, "swiftc"):
                module.generate(direct_frontend, tool_runner=FixtureToolRunner())

            external_frontend = fixture.root / "ExternalToolchain/swift-frontend"
            external_frontend.parent.mkdir()
            external_frontend.write_text("external swift\n", encoding="utf-8")
            fixture.swift_executable.unlink()
            fixture.swift_executable.symlink_to(external_frontend)
            run_git(fixture.root, "add", "-A")
            run_git(fixture.root, "commit", "-qm", "escaping swift symlink fixture")
            with self.assertRaisesRegex(module.ProvenanceError, "DEVELOPER_DIR"):
                module.generate(fixture.arguments(module), tool_runner=FixtureToolRunner())

    def test_release_rejects_untracked_ignored_or_tampered_gate_authority_source(self) -> None:
        module = load_generator_module()
        mutations = {
            "untracked": (
                "MacScope/Services/Phase2/QualificationGate/UntrackedGateSupport.swift",
                "struct UntrackedGateSupport {}\n",
                "clean|untracked",
            ),
            "ignored": (
                "MacScope/Services/Phase2/QualificationGate/IgnoredGateSupport.swift",
                "struct IgnoredGateSupport {}\n",
                "ordinary HEAD blob",
            ),
            "tampered": (
                "MacScope/Services/Phase2/QualificationGate/Phase2QualificationGateBuildAuthority.swift",
                "struct TamperedGateBuildAuthority {}\n",
                "clean|unstaged",
            ),
        }
        for name, (relative_path, contents, diagnostic) in mutations.items():
            with self.subTest(name=name), tempfile.TemporaryDirectory() as temporary_directory:
                fixture = ReleaseRepositoryFixture(Path(temporary_directory))
                path = fixture.root / relative_path
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(contents, encoding="utf-8")

                with self.assertRaisesRegex(module.ProvenanceError, diagnostic):
                    module.generate(
                        fixture.arguments(module),
                        tool_runner=FixtureToolRunner(),
                    )


if __name__ == "__main__":
    unittest.main()
