#!/usr/bin/env python3
"""Deterministic physical fixtures for the installed-acceptance E2E contract.

The fixture deliberately uses the production candidate and installer schemas.
Application and toolchain files, Git authority, and the atomic rename syscall
are represented inside a private temporary root. Native command execution is
simulated by the companion test; receipt and mutation validation remain real.
"""

from __future__ import annotations

import contextlib
from dataclasses import dataclass
import hashlib
import io
import json
import os
from pathlib import Path
import plistlib
import shutil
import struct
import subprocess
import tempfile
import time
from typing import Callable, Iterator
from unittest import mock
import zlib

from Scripts.check_local_signing_policy import (
    EXPECTED_RELEASE_PROVENANCE_SCALARS,
    RELEASE_PROVENANCE_SHA256_FIELDS,
)
from Scripts.generate_release_build_provenance import (
    NATIVE_DECOMPILER_GOLDEN_KEYS,
)
from Scripts.reconstruction import install_release_to_applications as installer
from Scripts.reconstruction import installed_matrix_receipt as matrix_receipt
from Scripts.reconstruction import native_live_preparation_receipt as native_preparation
from Scripts.reconstruction_gate_f.canonical_json import (
    canonical_bytes,
    decode_canonical_bytes,
)
from Scripts.reconstruction_gate_f.materialize_candidate_identity import (
    bundle_tree_digests,
)
from Scripts.reconstruction_gate_f.tests import candidate_mapping


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
INTEGRATION_REF = "HEAD"
RUN_ID = "installed-acceptance-e2e"
RUN_NONCE = "9" * 64
# This fixture starts with an absent destination and returns to absence after
# rollback; use the installer's actual canonical observation, not a placeholder.
PREDECESSOR_OBSERVATIONS_SHA256 = hashlib.sha256(
    canonical_bytes({"identity": None, "present": False})
).hexdigest()
TRANSACTION_NONCE = "7" * 64
BEGIN_TIME_NS = 4_000_000_000
EXPOSED_TIME_NS = 5_000_000_000

EXPECTED_BUNDLE_IDS = {
    "MacScope": "org.macscope.app",
    "CoreTests": "org.macscope.app.CoreTests",
    "AnalysisWorkerXPCService": "org.macscope.app.AnalysisWorker",
    "AIAgentWorkerXPCService": "org.macscope.app.AIAgentWorker",
    "NativeDecompilerXPCService": "org.macscope.app.NativeDecompiler",
    "ShellBrokerXPCService": "org.macscope.app.ShellBroker",
    "MacScopeInstalledAppUITests": (
        "org.macscope.app.MacScopeInstalledAppUITests"
    ),
    "MacScopeInstalledAppUITests-Runner": (
        "org.macscope.app.MacScopeInstalledAppUITests-Runner"
    ),
}


def sha256_bytes(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


def sha256_file(path: Path) -> str:
    return sha256_bytes(path.read_bytes())


def write_canonical(path: Path, document: object, *, mode: int = 0o600) -> str:
    path.parent.mkdir(parents=True, exist_ok=True)
    payload = canonical_bytes(document)
    path.write_bytes(payload)
    path.chmod(mode)
    return sha256_bytes(payload)


def read_canonical(path: Path) -> dict[str, object]:
    value = decode_canonical_bytes(path.read_bytes())
    if not isinstance(value, dict):
        raise AssertionError(f"expected a canonical object at {path}")
    return value


def _git_revision(revision: str) -> str:
    result = subprocess.run(
        ["/usr/bin/git", "rev-parse", revision],
        cwd=REPOSITORY_ROOT,
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        raise AssertionError(result.stderr)
    return result.stdout.strip()


def _git_blob(revision_path: str) -> bytes:
    result = subprocess.run(
        ["/usr/bin/git", "show", revision_path],
        cwd=REPOSITORY_ROOT,
        check=False,
        capture_output=True,
    )
    if result.returncode != 0:
        raise AssertionError(result.stderr.decode("utf-8", "replace"))
    return result.stdout


@dataclass(frozen=True)
class InstallerInvocation:
    status: int
    stdout: bytes
    stderr: bytes


class InstalledAcceptanceFixture:
    """One candidate, qualification, installation, and evidence authority."""

    def __init__(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(
            prefix="macscope-installed-acceptance-e2e."
        )
        self.root = Path(self.temporary.name).resolve()
        self.qualification_root = (
            self.root / "qualification" / "runs" / "run.e2e"
        )
        self.qualification_root.mkdir(parents=True)
        self.candidate_root = self.qualification_root / "candidate-artifacts"
        self.candidate_root.mkdir()
        self.candidate_path = self.candidate_root / "candidate.json"
        self.native_preparation_receipt = (
            self.candidate_root / "NativeLivePreparation.receipt.json"
        )
        self.installed_ui_preparation_receipt = (
            self.candidate_root / "InstalledUIPreparation.receipt.json"
        )
        self.qualification_receipt = self.qualification_root / "QUALIFICATION_INPUTS.json"
        self.coverage = self.qualification_root / "COVERAGE.json"
        self.result_bundle = self.qualification_root / "TestResults.xcresult"
        self.result_bundle.mkdir()
        self.applications_root = self.root / "Applications"
        self.applications_root.mkdir()
        self.installed_app = self.applications_root / "MacScope.app"
        self.work_root = self.root / "acceptance-work"
        self.work_root.mkdir(mode=0o700)
        self.installer_artifact_root = (
            self.work_root / "MacScopeInstaller.acceptance-artifacts"
        )
        self.source_commit = _git_revision(INTEGRATION_REF)
        self.repository_root = self.root / "fixture-repository"
        subprocess.run(
            ["/usr/bin/git", "clone", "--shared", "--no-checkout",
             str(REPOSITORY_ROOT), str(self.repository_root)],
            check=True, capture_output=True,
        )
        self.integration_ref = "refs/remotes/origin/installed-acceptance-e2e"
        subprocess.run(
            ["/usr/bin/git", "update-ref", self.integration_ref, self.source_commit],
            cwd=self.repository_root, check=True, capture_output=True,
        )
        self.source_tree = _git_revision(f"{self.source_commit}^{{tree}}")
        self.base_commit = _git_revision(f"{self.source_commit}^")
        self.base_tree = _git_revision(f"{self.base_commit}^{{tree}}")
        self.project_yml_sha256 = sha256_bytes(
            _git_blob(f"{self.source_commit}:MacScope/project.yml")
        )
        # The generated Xcode project is intentionally not tracked; its fixture
        # digest remains candidate authority but is never represented as a Git
        # blob identity.
        self.generated_project_sha256 = sha256_bytes(
            b'{"objects":{},"rootObject":"fixture"}'
        )
        developer_dir = self.root / "Xcode.app/Contents/Developer"
        xcodebuild = developer_dir / "usr/bin/xcodebuild"
        swiftc = developer_dir / "Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc"
        sdk_path = developer_dir / "Platforms/MacOSX.platform/Developer/SDKs/MacOSX27.0.sdk"
        for executable in (xcodebuild, swiftc, developer_dir / "usr/bin/lldb"):
            executable.parent.mkdir(parents=True, exist_ok=True)
            executable.write_bytes(b"#!/bin/sh\nexit 0\n")
            executable.chmod(0o700)
        xcodebuild.write_bytes(b'#!/bin/sh\nprintf "Xcode 27.0\\nBuild version 27A5252f\\n"\n')
        sdk_path.mkdir(parents=True)
        (sdk_path / "SDKSettings.json").write_bytes(b'{"fixture": "sdk"}')
        self.toolchain = {
            "developer_dir": str(developer_dir),
            "xcodebuild_sha256": sha256_file(xcodebuild),
            "xcode_version": "27.0",
            "xcode_build": "27A5252f",
            "swiftc_sha256": sha256_file(swiftc),
            "swift_version": (
                "swift-driver version: 1.168.6 Apple Swift version 6.4 "
                "(swiftlang-6.4.0.33.1 clang-2100.3.33.1)\n"
                "Target: arm64-apple-macosx27.0.0"
            ),
            "sdk_path": str(sdk_path),
            "sdk_settings_sha256": sha256_file(
                sdk_path / "SDKSettings.json"
            ),
            "sdk_version": "27.0",
            "sdk_build": "26A5419a",
        }
        self.swift_compiler_version, self.swift_host_target = native_preparation._swift_toolchain_values(
            self.toolchain["swift_version"]
        )
        self._make_native_prepared_products()
        self.source_app = self.prepared_app
        self._make_installed_ui_prepared_products()
        self._make_app(self.source_app)
        self._write_candidate()
        self._write_qualification()
        self._write_generated_project_evidence()
        self._write_preparation_receipts()
        self.candidate_authority = installer._load_source_authority(
            self.candidate_path, self.source_app
        )
        self.candidate_identity_sha256 = (
            self.candidate_authority.candidate_identity_sha256
        )
        self.pending_state = (
            self.applications_root
            / f".MacScope.pending-{self.candidate_identity_sha256}"
            / "transaction.json"
        )
        # Freeze a per-fixture clock after all source/preparation authorities
        # exist. Later create-only outputs then naturally postdate exposure.
        self.begin_time_ns = time.time_ns()
        self.exposed_time_ns = self.begin_time_ns + 1

    def cleanup(self) -> None:
        self.temporary.cleanup()

    def _make_bundle(self, bundle: Path, executable_name: str) -> None:
        executable = bundle / "Contents" / "MacOS" / executable_name
        executable.parent.mkdir(parents=True, exist_ok=True)
        executable.write_bytes(f"e2e:{executable_name}".encode("ascii"))
        executable.chmod(0o755)
        (bundle / "Contents" / "Info.plist").write_bytes(
            plistlib.dumps(
                {
                    "CFBundleExecutable": executable_name,
                    "CFBundleIdentifier": EXPECTED_BUNDLE_IDS[executable_name],
                },
                fmt=plistlib.FMT_BINARY,
                sort_keys=True,
            )
        )

    def _make_app(self, app: Path) -> None:
        self._make_bundle(app, "MacScope")
        self._make_bundle(
            app / "Contents" / "PlugIns" / "CoreTests.xctest",
            "CoreTests",
        )
        launch_agent = app / "Contents" / "MacOS" / "ShellBrokerLaunchAgent"
        launch_agent.write_bytes(b"e2e:ShellBrokerLaunchAgent")
        (app / "Contents/MacOS/SourceExecutionRunner").write_bytes(b"fixture:SourceExecutionRunner")
        launch_agent.chmod(0o755)
        xpc_root = app / "Contents" / "XPCServices"
        for executable_name in (
            "AnalysisWorkerXPCService",
            "AIAgentWorkerXPCService",
            "NativeDecompilerXPCService",
            "ShellBrokerXPCService",
        ):
            self._make_bundle(
                xpc_root / f"{executable_name}.xpc", executable_name
            )
        native_code_resources = (
            xpc_root
            / "NativeDecompilerXPCService.xpc"
            / "Contents"
            / "_CodeSignature"
            / "CodeResources"
        )
        native_code_resources.parent.mkdir(parents=True)
        native_code_resources.write_bytes(b"e2e:NativeDecompiler:CodeResources")

        provenance: dict[str, object] = {
            field: sha256_bytes(f"e2e:{field}".encode("ascii"))
            for field in RELEASE_PROVENANCE_SHA256_FIELDS
        }
        provenance.update(EXPECTED_RELEASE_PROVENANCE_SCALARS)
        native_golden_result = {
            field: sha256_bytes(f"e2e:{field}".encode("ascii"))
            for field in NATIVE_DECOMPILER_GOLDEN_KEYS
            if field.endswith("SHA256")
        }
        native_golden_result.update(
            {
                "architecture": "arm64",
                "backendID": "macscope-native-decompiler",
                "deploymentTarget": "27.0",
                "engineGitRevision": "b" * 40,
                "engineVersion": "e2e",
                "passed": True,
                "schemaVersion": 1,
                "sdkBuild": self.toolchain["sdk_build"],
                "sdkName": f"macosx{self.toolchain['sdk_version']}",
                "sdkVersion": self.toolchain["sdk_version"],
                "swiftCompilerVersion": self.swift_compiler_version,
                "swiftTargetTriple": self.swift_host_target,
                "wrapperGitRevision": "c" * 40,
                "wrapperVersion": "e2e",
                "xcodeBuild": self.toolchain["xcode_build"],
                "xcodeVersion": self.toolchain["xcode_version"],
            }
        )
        provenance.update(
            {
                "git_head_commit": self.source_commit,
                "git_head_tree": self.source_tree,
                "project_yml_sha256": self.project_yml_sha256,
                "xcode_version": self.toolchain["xcode_version"],
                "xcode_build": self.toolchain["xcode_build"],
                "swift_compiler_version": self.swift_compiler_version,
                "swift_target_triple": self.swift_host_target,
                "sdk_version": self.toolchain["sdk_version"],
                "sdk_build": self.toolchain["sdk_build"],
                "sdk_name": f"macosx{self.toolchain['sdk_version']}",
                "machokit_analysis_worker_executable_sha256": sha256_file(
                    xpc_root
                    / "AnalysisWorkerXPCService.xpc"
                    / "Contents"
                    / "MacOS"
                    / "AnalysisWorkerXPCService"
                ),
                "native_decompiler_embedded_service_executable_sha256": sha256_file(
                    xpc_root
                    / "NativeDecompilerXPCService.xpc"
                    / "Contents"
                    / "MacOS"
                    / "NativeDecompilerXPCService"
                ),
                "native_decompiler_embedded_service_code_resources_sha256": sha256_file(
                    native_code_resources
                ),
                "native_decompiler_embedded_service_bundle_identifier": (
                    "org.macscope.app.NativeDecompiler"
                ),
                "native_decompiler_golden_result": native_golden_result,
            }
        )
        for field in (
            "ghostty_source_dir_sha256",
            "machokit_materialization_manifest_sha256",
            "machokit_materialization_root_sha256",
            "machokit_materialization_tree_sha256",
            "machokit_source_archive_sha256",
            "machokit_upstream_tree_sha256",
            "native_decompiler_embedded_decompiler_archive_sha256",
            "native_decompiler_embedded_manifest_sha256",
            "native_decompiler_embedded_service_info_plist_sha256",
            "native_decompiler_embedded_sleigh_archive_sha256",
            "native_decompiler_embedded_tree_sha256",
            "sleigh_materialization_manifest_sha256",
            "sleigh_materialization_root_sha256",
            "sleigh_materialization_tree_sha256",
            "third_party_manifest_sha256",
            "third_party_notices_sha256",
        ):
            provenance[field] = sha256_bytes(f"e2e:{field}".encode("ascii"))
        provenance.update(
            {
                "ai_worker_bundle_identifier": (
                    "org.macscope.app.AIAgentWorker"
                ),
                "dependency_root_authority": (
                    "xcode-resolved-build-settings"
                ),
                "machokit_analysis_worker_compiled_identity": {
                    "governed_source_identity": sha256_bytes(
                        b"e2e:machokit-governed-source"
                    ),
                    "revision": "a" * 40,
                    "schema": "macscope-machokit-compiled-identity-v1",
                },
                "machokit_analysis_worker_executable_size": (
                    xpc_root
                    / "AnalysisWorkerXPCService.xpc"
                    / "Contents/MacOS/AnalysisWorkerXPCService"
                ).stat().st_size,
                "machokit_governed_source_identity": sha256_bytes(
                    b"e2e:machokit-governed-source"
                ),
                "machokit_revision": "a" * 40,
                "machokit_version": "0.52.2",
                "native_decompiler_golden_result_sha256": sha256_bytes(
                    canonical_bytes(
                        provenance["native_decompiler_golden_result"]
                    )
                ),
                "sleigh_materialization_component_id": (
                    "sleigh-native-dcp03b4"
                ),
                "sleigh_materialization_schema_version": 1,
                "swift_language_version": "6.0",
                "third_party_component_count": 1,
                "third_party_component_ids": ["fixture-tool"],
                "third_party_distribution_status": (
                    "private-development-only"
                ),
                "third_party_public_distribution_approved": False,
                "xcodegen_version": "2.45.4",
            }
        )
        self.provenance_path = app / installer.BUILD_PROVENANCE_RELATIVE_PATH
        self.provenance_path.parent.mkdir(parents=True, exist_ok=True)
        self.provenance_path.write_bytes(
            json.dumps(
                provenance,
                ensure_ascii=True,
                allow_nan=False,
                sort_keys=True,
                separators=(",", ":"),
            ).encode("utf-8")
            + b"\n"
        )
        self.provenance_path.chmod(0o644)

    def _make_native_prepared_products(self) -> None:
        self.prepared_products = (
            self.qualification_root / "DerivedData" / "Build" / "Products"
        )
        self.prepared_debug = self.prepared_products / "Debug"
        self.prepared_app = self.prepared_products / "Release/MacScope.app"
        self._make_bundle(self.prepared_app, "MacScope")
        self.prepared_native_bundle = (
            self.prepared_app
            / "Contents"
            / "XPCServices"
            / "NativeDecompilerXPCService.xpc"
        )
        self._make_bundle(self.prepared_native_bundle, "NativeDecompilerXPCService")
        self.debug_test_host = self.prepared_debug / "MacScope.app"
        self._make_bundle(self.debug_test_host, "MacScope")
        self.prepared_core_tests = (
            self.debug_test_host / "Contents" / "PlugIns" / "CoreTests.xctest"
        )
        self._make_bundle(self.prepared_core_tests, "CoreTests")
        self.native_xctestrun = (
            self.prepared_products / f"MacScopeApp_macosx{self.toolchain['sdk_version']}-arm64.xctestrun"
        )
        with self.native_xctestrun.open("wb") as stream:
            plistlib.dump(
                {
                    "__xctestrun_metadata__": {
                        "ContainerInfo": {"SchemeName": "MacScopeApp"}
                    },
                    "CoreTests": {
                        "BlueprintName": "CoreTests",
                        "DependentProductPaths": [
                            "__TESTROOT__/Debug/MacScope.app",
                            "__TESTROOT__/Debug/MacScope.app/Contents/PlugIns/CoreTests.xctest",
                        ],
                        "IsAppHostedTestBundle": True,
                        "TestHostBundleIdentifier": "org.macscope.app",
                        "TestHostPath": "__TESTROOT__/Debug/MacScope.app",
                        "TestBundlePath": (
                            "__TESTHOST__/Contents/PlugIns/CoreTests.xctest"
                        ),
                    },
                },
                stream,
            )

    def _make_installed_ui_prepared_products(self) -> None:
        self.ui_runner = (
            self.prepared_debug / "MacScopeInstalledAppUITests-Runner.app"
        )
        self._make_bundle(
            self.ui_runner,
            "MacScopeInstalledAppUITests-Runner",
        )
        self.ui_test_bundle = (
            self.ui_runner
            / "Contents"
            / "PlugIns"
            / "MacScopeInstalledAppUITests.xctest"
        )
        self._make_bundle(self.ui_test_bundle, "MacScopeInstalledAppUITests")
        self.installed_ui_xctestrun = (
            self.prepared_products
            / f"MacScopeInstalledAppUITests_macosx{self.toolchain['sdk_version']}-arm64.xctestrun"
        )
        with self.installed_ui_xctestrun.open("wb") as stream:
            plistlib.dump(
                {
                    "__xctestrun_metadata__": {
                        "ContainerInfo": {
                            "SchemeName": native_preparation.INSTALLED_UI_SCHEME
                        }
                    },
                    "MacScopeInstalledAppUITests": {
                        "BlueprintName": "MacScopeInstalledAppUITests",
                        "DependentProductPaths": [
                            "__TESTROOT__/Debug/MacScope.app",
                            (
                                "__TESTROOT__/Debug/"
                                "MacScopeInstalledAppUITests-Runner.app"
                            ),
                            (
                                "__TESTHOST__/Contents/PlugIns/"
                                "MacScopeInstalledAppUITests.xctest"
                            ),
                        ],
                        "EnvironmentVariables": {"TERM": "dumb"},
                        "TestingEnvironmentVariables": {
                            "XCODE_SCHEME_NAME": (
                                native_preparation.INSTALLED_UI_SCHEME
                            )
                        },
                        "TestHostPath": (
                            "__TESTROOT__/Debug/"
                            "MacScopeInstalledAppUITests-Runner.app"
                        ),
                        "TestBundlePath": (
                            "__TESTHOST__/Contents/PlugIns/"
                            "MacScopeInstalledAppUITests.xctest"
                        ),
                        "UITargetAppPath": "__TESTROOT__/Debug/MacScope.app",
                    },
                },
                stream,
            )

    def _write_candidate(self) -> None:
        mapping = candidate_mapping()
        mapping["source"].update(
            {
                "repository": "origin:MacScope",
                "base_commit": self.base_commit,
                "base_tree": self.base_tree,
                "branch_label": self.integration_ref.removeprefix(
                    "refs/remotes/origin/"
                ),
                "commit": self.source_commit,
                "dirty": False,
                "generated_project_sha256": self.generated_project_sha256,
                "project_yml_sha256": self.project_yml_sha256,
                "tree": self.source_tree,
            }
        )
        digests = bundle_tree_digests(self.source_app)
        application = mapping["application"]
        application["bundle_identifier"] = EXPECTED_BUNDLE_IDS["MacScope"]
        application["bundle_sha256"] = digests.content_sha256
        application["closed_tree_sha256"] = digests.closed_tree_sha256
        application["root_mode"] = self.source_app.stat().st_mode & 0o7777
        application["executable_sha256"] = sha256_file(
            self.source_app / "Contents" / "MacOS" / "MacScope"
        )
        names = {
            "analysis-worker": "AnalysisWorkerXPCService",
            "ai-agent-worker": "AIAgentWorkerXPCService",
            "native-decompiler": "NativeDecompilerXPCService",
            "shell-broker": "ShellBrokerXPCService",
        }
        application["embedded_executables"] = [
            {
                "identity_id": identity_id,
                "sha256": sha256_file(
                    self.source_app
                    / "Contents"
                    / "XPCServices"
                    / f"{name}.xpc"
                    / "Contents"
                    / "MacOS"
                    / name
                ),
            }
            for identity_id, name in sorted(names.items())
        ]
        tools = {item["tool_id"]: item for item in mapping["tools"]}
        tools["xcode"].update(
            {
                "identity_sha256": self.toolchain["xcodebuild_sha256"],
                "version": (
                    f"Xcode {self.toolchain['xcode_version']} | "
                    f"Build version {self.toolchain['xcode_build']}"
                ),
            }
        )
        tools["swift"].update(
            {
                "identity_sha256": self.toolchain["swiftc_sha256"],
                "version": self.toolchain["swift_version"].replace("\n", " | "),
            }
        )
        tools["sdk"].update(
            {
                "identity_sha256": self.toolchain["sdk_settings_sha256"],
                "version": self.toolchain["sdk_version"],
            }
        )
        qualifications = {
            item["identity_id"]: item
            for item in application["qualification_executables"]
        }
        prepared_app_executable = self.prepared_app / "Contents" / "MacOS" / "MacScope"
        prepared_native_executable = (
            self.prepared_native_bundle
            / "Contents"
            / "MacOS"
            / "NativeDecompilerXPCService"
        )
        for identity_id in ("app", "native-live-app"):
            qualifications[identity_id].update(
                {
                    "bundle_identifier": "org.macscope.app",
                    "sha256": sha256_file(prepared_app_executable),
                }
            )
        qualifications["native-decompiler"].update(
            {
                "bundle_identifier": "org.macscope.app.NativeDecompiler",
                "sha256": sha256_file(prepared_native_executable),
            }
        )
        write_canonical(self.candidate_path, mapping)

    def _write_generated_project_evidence(self) -> None:
        from Scripts.qualification import generated_project_evidence
        from Scripts.qualification.restore_build_source import (
            GENERATED_PROJECT_FILES, _generated_project_identity,
        )
        source = self.qualification_root / "source/MacScope"
        source.mkdir(parents=True, exist_ok=True)
        (source / "project.yml").write_bytes(_git_blob(f"{self.source_commit}:MacScope/project.yml"))
        project = source / "MacScope.xcodeproj"
        for relative in sorted(GENERATED_PROJECT_FILES):
            path = project / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b'{"objects":{},"rootObject":"fixture"}' if relative == "project.xcproj"
                             else f"e2e fixture: {relative}\n".encode())
        generated_project_evidence.capture(
            self.qualification_root,
            _generated_project_identity(project, require_complete=True),
        )

    def _write_qualification(self) -> None:
        source_root = self.qualification_root / "source"
        dependency_cache_root = self.root / "dependency-cache"
        ghostty_root = (
            self.qualification_root / "dependencies/ghostty-vt-qualification"
        )
        surface_root = (
            self.qualification_root
            / "dependencies/ghostty-surface/GhosttySurface"
        )
        surface_artifact_root = (
            surface_root / "macos/GhosttyKit.xcframework"
        )
        sleigh_root = (
            self.qualification_root
            / "dependencies/sleigh-native-source/SleighNativeSource/materialization"
        )
        for directory in (
            source_root,
            dependency_cache_root,
            ghostty_root,
            surface_artifact_root,
            sleigh_root,
        ):
            directory.mkdir(parents=True, exist_ok=True)
        zig = source_root / "ThirdParty/Zig/zig-0.16.0/zig"
        zig.parent.mkdir(parents=True)
        zig.write_bytes(b"#!/bin/sh\nexit 0\n")
        zig.chmod(0o755)
        vt_manifest = ghostty_root / "zig-out/lib/.macscope-ghostty-vt-manifest"
        vt_manifest.parent.mkdir(parents=True)
        vt_manifest.write_bytes(b"schema=5\n")
        surface_manifest = surface_root / "macos/.macscope-ghostty-surface-manifest"
        surface_manifest.parent.mkdir(parents=True, exist_ok=True)
        surface_manifest.write_bytes(b"schema=3\n")
        sleigh_manifest = sleigh_root / "MATERIALIZATION.json"
        sleigh_manifest.write_bytes(canonical_bytes({"fixture": "sleigh"}))
        source_files = {"files": [], "schema_version": 2}
        source_files_payload = canonical_bytes(source_files) + b"\n"
        (source_root / "SOURCE_FILES.json").write_bytes(source_files_payload)
        remote_url_result = subprocess.run(
            [
                "/usr/bin/git",
                "config",
                "--local",
                "--get",
                "remote.origin.url",
            ],
            cwd=self.repository_root,
            check=True,
            capture_output=True,
            text=True,
        )
        source_identity = {
            "canonical_integration_commit": self.source_commit,
            "canonical_integration_ref": self.integration_ref,
            "canonical_remote_url": remote_url_result.stdout.strip(),
            "dependency_contract": {},
            "git_head_commit": self.source_commit,
            "git_head_tree": self.source_tree,
            "git_parent_commits": [self.base_commit],
            "repository_clean": True,
            "schema_version": 2,
            "source_file_count": 0,
            "source_files_sha256": sha256_bytes(source_files_payload),
        }
        (source_root / "SOURCE_PROVENANCE.json").write_bytes(
            canonical_bytes(source_identity) + b"\n"
        )
        qualification = {
            "build_source_root": str(source_root),
            "dependency_cache_root": str(dependency_cache_root),
            "dependency_network_allowed": False,
            "dependency_network_used": False,
            "ghostty_artifact_manifest_sha256": sha256_file(vt_manifest),
            "ghostty_source_dir": str(ghostty_root),
            "ghostty_surface_artifact_root": str(surface_artifact_root),
            "ghostty_surface_manifest_sha256": sha256_file(
                surface_manifest
            ),
            "ghostty_surface_source_dir": str(surface_root),
            "mode": "full-test",
            "schema_version": 4,
            "sleigh_materialization_manifest_sha256": sha256_file(
                sleigh_manifest
            ),
            "sleigh_materialization_root": str(sleigh_root),
            "source_identity": source_identity,
            "zig_executable": str(zig),
        }
        self.qualification_receipt.write_bytes(
            canonical_bytes(qualification) + b"\n"
        )
        self.qualification_receipt.chmod(0o600)
        write_canonical(self.coverage, {"result": "passed"})

    def _write_preparation_receipts(self) -> None:
        candidate = read_canonical(self.candidate_path)
        source = candidate["source"]
        assert isinstance(source, dict)
        prepared_native = (
            self.source_app
            / "Contents"
            / "XPCServices"
            / "NativeDecompilerXPCService.xpc"
            / "Contents"
            / "MacOS"
            / "NativeDecompilerXPCService"
        )
        prepared_app_executable = (
            self.source_app / "Contents" / "MacOS" / "MacScope"
        )
        core_executable = self.prepared_core_tests / "Contents/MacOS/CoreTests"
        native_document = {
            "artifacts": {
                "app": {
                    "closed_tree_sha256": bundle_tree_digests(
                        self.source_app
                    ).closed_tree_sha256,
                    "executable_sha256": sha256_file(prepared_app_executable),
                    "path": str(self.source_app),
                },
                "core_tests": {
                    "closed_tree_sha256": bundle_tree_digests(self.prepared_core_tests).closed_tree_sha256,
                    "executable_sha256": sha256_file(core_executable),
                    "path": str(self.prepared_core_tests),
                },
                "native_decompiler": {
                    "path": str(prepared_native),
                    "sha256": sha256_file(prepared_native),
                },
                "xctestrun": {
                    "path": str(self.native_xctestrun),
                    "sha256": sha256_file(self.native_xctestrun),
                },
            },
            "build": {
                "configuration": native_preparation.CONFIGURATION,
                "destination": native_preparation.DESTINATION,
                "live_test_condition": native_preparation.LIVE_TEST_CONDITION,
                "preparation_mode": native_preparation.NATIVE_LIVE_PREPARATION_MODE,
                "scheme": native_preparation.SCHEME,
            },
            "receipt_kind": native_preparation.RECEIPT_KIND,
            "schema_version": native_preparation.SCHEMA_VERSION,
            "source": {
                field: source[field]
                for field in (
                    "branch_label",
                    "commit",
                    "dirty",
                    "generated_project_sha256",
                    "project_yml_sha256",
                    "repository",
                    "tree",
                )
            },
            "toolchain": dict(self.toolchain),
        }
        write_canonical(self.native_preparation_receipt, native_document)
        prepared_ui_app_executable = (
            self.prepared_app / "Contents" / "MacOS" / "MacScope"
        )
        ui_test_executable = (
            self.ui_test_bundle
            / "Contents"
            / "MacOS"
            / "MacScopeInstalledAppUITests"
        )
        ui_runner_executable = (
            self.ui_runner
            / "Contents"
            / "MacOS"
            / "MacScopeInstalledAppUITests-Runner"
        )
        installed_ui_document = {
            "artifacts": {
                "app": {
                    "closed_tree_sha256": bundle_tree_digests(
                        self.prepared_app
                    ).closed_tree_sha256,
                    "executable_sha256": sha256_file(
                        prepared_ui_app_executable
                    ),
                    "path": str(self.prepared_app),
                },
                "ui_runner": {
                    "closed_tree_sha256": bundle_tree_digests(
                        self.ui_runner
                    ).closed_tree_sha256,
                    "executable_sha256": sha256_file(ui_runner_executable),
                    "path": str(self.ui_runner),
                },
                "ui_test_bundle": {
                    "closed_tree_sha256": bundle_tree_digests(
                        self.ui_test_bundle
                    ).closed_tree_sha256,
                    "executable_sha256": sha256_file(ui_test_executable),
                    "path": str(self.ui_test_bundle),
                },
                "xctestrun": {
                    "path": str(self.installed_ui_xctestrun),
                    "sha256": sha256_file(self.installed_ui_xctestrun),
                },
            },
            "build": {
                "configuration": native_preparation.CONFIGURATION,
                "destination": native_preparation.DESTINATION,
                "live_test_condition": (
                    native_preparation.INSTALLED_UI_TEST_CONDITION
                ),
                "preparation_mode": (
                    native_preparation.INSTALLED_UI_PREPARATION_MODE
                ),
                "scheme": native_preparation.INSTALLED_UI_SCHEME,
            },
            "receipt_kind": native_preparation.RECEIPT_KIND,
            "schema_version": native_preparation.SCHEMA_VERSION,
            "source": native_document["source"],
            "toolchain": dict(self.toolchain),
        }
        write_canonical(
            self.installed_ui_preparation_receipt,
            installed_ui_document,
        )

    @staticmethod
    def atomic_rename(source: Path, destination: Path, flags: int) -> None:
        if flags == installer.RENAME_EXCL:
            if destination.exists() or destination.is_symlink():
                raise FileExistsError(destination)
            os.rename(source, destination)
            return
        if flags != installer.RENAME_SWAP:
            raise AssertionError(f"unexpected rename flags: {flags}")
        temporary = source.with_name(source.name + ".e2e-swap")
        os.rename(source, temporary)
        os.rename(destination, source)
        os.rename(temporary, destination)

    def installer_arguments(
        self,
        phase: str,
        *,
        acceptance_gate_inputs: dict[str, Path] | None = None,
    ) -> list[str]:
        arguments = [
            "--phase",
            phase,
            "--transaction-token",
            self.candidate_identity_sha256,
            "--candidate-identity",
            str(self.candidate_path),
            "--source-app",
            str(self.source_app),
            "--installed-app",
            str(self.installed_app),
            "--artifact-root",
            str(self.installer_artifact_root),
            "--qualification-run-id",
            RUN_ID,
            "--qualification-run-nonce",
            RUN_NONCE,
            "--predecessor-observations-sha256",
            PREDECESSOR_OBSERVATIONS_SHA256,
        ]
        if acceptance_gate_inputs:
            for gate_id in installer.REQUIRED_ACCEPTANCE_GATES:
                arguments.extend(
                    [
                        "--acceptance-gate-input",
                        f"{gate_id}={acceptance_gate_inputs[gate_id]}",
                    ]
                )
        return arguments

    def run_installer(
        self,
        phase: str,
        *,
        acceptance_gate_inputs: dict[str, Path] | None = None,
        clock: Callable[[], int] | None = None,
    ) -> InstallerInvocation:
        times: Iterator[int] = iter(
            (self.begin_time_ns, self.exposed_time_ns)
        )
        effective_clock = clock or (lambda: next(times))
        stdout = io.StringIO()
        stderr = io.StringIO()
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            status = installer.main(
                self.installer_arguments(
                    phase, acceptance_gate_inputs=acceptance_gate_inputs
                ),
                _allow_test_destination=True,
                _atomic_rename=self.atomic_rename,
                _clock_ns=effective_clock,
                _transaction_nonce_factory=lambda: TRANSACTION_NONCE,
            )
        return InstallerInvocation(
            status=status,
            stdout=stdout.getvalue().encode("utf-8"),
            stderr=stderr.getvalue().encode("utf-8"),
        )

    def begin(self) -> dict[str, object]:
        result = self.run_installer("begin")
        if result.status != 0:
            raise AssertionError(result.stderr.decode("utf-8", "replace"))
        if not self.pending_state.is_file():
            raise AssertionError("production installer did not publish pending state")
        return read_canonical(self.pending_state)

    def reset_after_rollback(self) -> None:
        if self.work_root.exists():
            shutil.rmtree(self.work_root)
        for overlay in self.prepared_products.glob(
            "*-Task10OptIn-*.xctestrun"
        ):
            overlay.unlink()
        self.work_root.mkdir(mode=0o700)
        self.installer_artifact_root = (
            self.work_root / "MacScopeInstaller.acceptance-artifacts"
        )

    def transaction_arguments(self, compiler: Path) -> list[str]:
        return [
            "--gate-plan-compiler",
            str(compiler),
            "--qualification-receipt",
            str(self.qualification_receipt),
            "--qualification-run-id",
            RUN_ID,
            "--qualification-run-nonce",
            RUN_NONCE,
            "--predecessor-observations-sha256",
            PREDECESSOR_OBSERVATIONS_SHA256,
            "--candidate-artifact-root",
            str(self.candidate_root),
            "--work-root",
            str(self.work_root),
            "--installed-app",
            str(self.installed_app),
            "--begin-timeout-seconds",
            "60",
            "--compiler-timeout-seconds",
            "60",
            "--report-timeout-seconds",
            "60",
            "--commit-timeout-seconds",
            "60",
            "--rollback-timeout-seconds",
            "60",
            "--result-output",
            str(self.work_root / "InstalledAcceptanceTransaction.result.json"),
        ]

    @staticmethod
    def _png(width: int, height: int, marker: int) -> bytes:
        def chunk(kind: bytes, payload: bytes) -> bytes:
            return (
                len(payload).to_bytes(4, "big")
                + kind
                + payload
                + zlib.crc32(kind + payload).to_bytes(4, "big")
            )

        first_pixel = bytes(
            (marker % 256, (marker * 17) % 256, (marker * 31) % 256)
        )
        first_row = b"\x00" + first_pixel + b"\x00\x00\x00" * (width - 1)
        rows = first_row + b"".join(
            b"\x00" + b"\x00\x00\x00" * width
            for _ in range(height - 1)
        )
        return (
            b"\x89PNG\r\n\x1a\n"
            + chunk(
                b"IHDR",
                struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0),
            )
            + chunk(b"IDAT", zlib.compress(rows))
            + chunk(b"IEND", b"")
        )

    def publish_xcresult_export(
        self,
        output_root: Path,
        selector_projection: list[dict[str, object]],
    ) -> None:
        """Stand in only for xcresulttool's physical attachment export."""

        output_root.mkdir(mode=0o700)
        if output_root.name.endswith(".accessibility-observations"):
            manifest: list[dict[str, object]] = []
            for index, item in enumerate(selector_projection):
                exported = f"observation-{index:02d}.json"
                write_canonical(
                    output_root / exported,
                    {
                        "observedIdentifiers": sorted(
                            item["required_identifiers"]
                        ),
                        "schemaVersion": 1,
                        "testIdentifier": item["test_identifier"],
                        "vectorID": item["vector_id"],
                    },
                )
                manifest.append(
                    {
                        "attachments": [
                            {
                                "exportedFileName": exported,
                                "isAssociatedWithFailure": False,
                                "suggestedHumanReadableName": (
                                    matrix_receipt
                                    .ACCESSIBILITY_OBSERVATION_ATTACHMENT_NAME
                                ),
                            }
                        ],
                        "testIdentifier": item["test_identifier"],
                    }
                )
            (output_root / "manifest.json").write_text(
                json.dumps(manifest, sort_keys=True),
                encoding="utf-8",
            )
            return

        if not output_root.name.endswith(".presentation-screenshots"):
            raise AssertionError(f"unexpected xcresult export root: {output_root}")
        candidate, _digest = matrix_receipt._candidate(self.candidate_path)
        attachments: list[dict[str, object]] = []
        for marker, (
            presentation_state,
            appearance,
            window_size,
            width,
            height,
        ) in enumerate(matrix_receipt.PRESENTATION_VARIANTS, start=1):
            exported = f"{presentation_state}-{appearance}-{window_size}.png"
            (output_root / exported).write_bytes(
                self._png(width, height, marker)
            )
            attachments.append(
                {
                    "configurationName": "Debug",
                    "deviceId": "mac",
                    "deviceName": "Mac",
                    "exportedFileName": exported,
                    "isAssociatedWithFailure": False,
                    "suggestedHumanReadableName": (
                        matrix_receipt._expected_presentation_attachment_name(
                            candidate,
                            presentation_state,
                            appearance,
                            window_size,
                        )
                    ),
                }
            )
        (output_root / "manifest.json").write_text(
            json.dumps(
                [
                    {
                        "attachments": attachments,
                        "testIdentifier": (
                            matrix_receipt.PRESENTATION_TEST_IDENTIFIER
                        ),
                    }
                ],
                sort_keys=True,
            ),
            encoding="utf-8",
        )


__all__ = [
    "BEGIN_TIME_NS",
    "EXPOSED_TIME_NS",
    "INTEGRATION_REF",
    "InstalledAcceptanceFixture",
    "InstallerInvocation",
    "PREDECESSOR_OBSERVATIONS_SHA256",
    "REPOSITORY_ROOT",
    "RUN_ID",
    "RUN_NONCE",
    "read_canonical",
    "sha256_bytes",
    "sha256_file",
    "write_canonical",
]
