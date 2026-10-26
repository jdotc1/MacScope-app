#!/usr/bin/env python3
"""Guard MacScope's persistent local code-signing identity."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import plistlib
import re
import stat
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Callable


REPOSITORY_ROOT = Path(__file__).resolve().parents[1]
if str(REPOSITORY_ROOT) not in sys.path:
    sys.path.insert(0, str(REPOSITORY_ROOT))


def _debug_signing_stamp_candidate(arguments: list[str]) -> bool:
    """Only the exact routine-Debug Xcode phase invocation may reuse a stamp.

    Release, every qualification/Gate F/CI build (source-qualified identity),
    and every other command-line form always run the full validation.
    """
    environment_target = os.environ.get("TARGET_NAME", "")
    return (
        arguments == ["--build-environment", "--target", environment_target]
        and bool(environment_target)
        and os.environ.get("CONFIGURATION") == "Debug"
        and os.environ.get("MACSCOPE_DEBUG_SOURCE_IDENTITY") == "runtime-only"
    )


def _load_debug_phase_stamp():
    """Load the stdlib-only stamp helper without writing repository bytecode."""
    import importlib.util

    path = Path(__file__).resolve().parent / "build_phase_stamp.py"
    specification = importlib.util.spec_from_file_location(
        "macscope_build_phase_stamp", path
    )
    if specification is None or specification.loader is None:
        raise ImportError("build_phase_stamp.py is unavailable")
    module = importlib.util.module_from_spec(specification)
    previous = sys.dont_write_bytecode
    sys.dont_write_bytecode = True
    try:
        specification.loader.exec_module(module)
    finally:
        sys.dont_write_bytecode = previous
    return module


# Routine Debug fast path, evaluated before the heavier policy imports below.
# The per-target stamp is keyed on this script, the generation-freshness inputs
# and stamp, the generated project and the complete phase environment, so an
# unchanged target environment skips only a re-validation of identical inputs.
_DEBUG_SIGNING_STAMP = None
if __name__ == "__main__" and _debug_signing_stamp_candidate(sys.argv[1:]):
    try:
        _DEBUG_SIGNING_STAMP = _load_debug_phase_stamp()
        if _DEBUG_SIGNING_STAMP.check("signing-environment", dict(os.environ)):
            print(
                "note: signing-environment: inputs and environment unchanged since "
                "the last verified Debug run; reusing its stamp"
            )
            raise SystemExit(0)
    except SystemExit:
        raise
    except Exception as _stamp_error:  # never skip validation on a stamp fault
        print(
            f"warning: signing-environment stamp ignored: {_stamp_error}",
            file=sys.stderr,
        )
        _DEBUG_SIGNING_STAMP = None

from Scripts.xcode_project_json import read_project
from Scripts.reconstruction_gate_f.canonical_json import canonical_text  # noqa: E402
from Scripts.reconstruction_gate_f.materialize_candidate_identity import (  # noqa: E402
    CandidateMaterializationError,
    bundle_tree_digests,
)


EXPECTED_DEPLOYMENT_TARGET = "27.0"
EXPECTED_SIGNER_SUBJECT = "Apple Development: MacScope Developer (CERT000000)"
EXPECTED_TEAM_IDENTIFIER = "TEAM000000"
from Scripts.project_freshness import (  # noqa: E402  (moved; re-exported for callers and tests)
    PROJECT_FRESHNESS_INPUTS,
    PROJECT_FRESHNESS_LABELS,
    PROJECT_FRESHNESS_READ_BOUND,
    PROJECT_FRESHNESS_SOURCE_PATHS_LABEL,
    PROJECT_FRESHNESS_SOURCE_PATH_ROOTS,
    PROJECT_FRESHNESS_SOURCE_WALK_SKIP,
    PROJECT_FRESHNESS_STAMP_NAME,
    PROJECT_FRESHNESS_STAMP_PATTERN,
    PROJECT_FRESHNESS_STAMP_SIZE,
    generated_project_freshness_inputs,
    generated_project_freshness_payload,
    generated_project_freshness_stamp,
    generated_project_source_paths,
    generated_project_source_paths_digest,
    record_generated_project_freshness,
    sha256_stable_regular_file,
    validate_generated_project_freshness,
)
EXPECTED_PROJECT_SETTINGS = {
    ("options", "deploymentTarget", "macOS"): EXPECTED_DEPLOYMENT_TARGET,
    ("settings", "base", "MACOSX_DEPLOYMENT_TARGET"): EXPECTED_DEPLOYMENT_TARGET,
    ("settings", "base", "AD_HOC_CODE_SIGNING_ALLOWED"): "NO",
    ("settings", "base", "CODE_SIGNING_ALLOWED"): "YES",
    ("settings", "base", "CODE_SIGNING_REQUIRED"): "YES",
    ("settings", "base", "CODE_SIGN_STYLE"): "Manual",
    ("settings", "base", "DEVELOPMENT_TEAM"): "$(MACSCOPE_SIGNING_TEAM)",
    ("settings", "base", "CODE_SIGN_IDENTITY"): "$(MACSCOPE_SIGNING_IDENTITY)",
    ("settings", "base", "PROVISIONING_PROFILE"): "",
    ("settings", "base", "PROVISIONING_PROFILE_SPECIFIER"): "",
    ("settings", "base", "ENABLE_HARDENED_RUNTIME"): "YES",
    ("settings", "base", "OTHER_CODE_SIGN_FLAGS"): "",
    ("settings", "configs", "Debug", "CODE_SIGN_ENTITLEMENTS"): "",
    (
        "settings",
        "configs",
        "Debug",
        "CODE_SIGN_INJECT_BASE_ENTITLEMENTS",
    ): "YES",
    (
        "settings",
        "configs",
        "Debug",
        "SWIFT_OPTIMIZATION_LEVEL",
    ): "-Onone",
    ("settings", "configs", "Release", "CODE_SIGN_ENTITLEMENTS"): "",
    ("settings", "configs", "Release", "CODE_SIGN_INJECT_BASE_ENTITLEMENTS"): "YES",
    (
        "targets",
        "MacScopeApp",
        "settings",
        "base",
        "PRODUCT_BUNDLE_IDENTIFIER",
    ): "org.macscope.app",
    (
        "targets",
        "MacScopeApp",
        "settings",
        "base",
        "GENERATE_INFOPLIST_FILE",
    ): "NO",
    (
        "targets",
        "MacScopeApp",
        "settings",
        "base",
        "INFOPLIST_FILE",
    ): "Resources/Info.plist",
    ("targets", "MacScopeApp", "deploymentTarget"): EXPECTED_DEPLOYMENT_TARGET,
    ("targets", "PluginXPCService", "deploymentTarget"): EXPECTED_DEPLOYMENT_TARGET,
    (
        "targets",
        "PluginXPCService",
        "settings",
        "base",
        "PRODUCT_BUNDLE_IDENTIFIER",
    ): "org.macscope.app.PluginXPCService",
    (
        "targets",
        "PluginXPCService",
        "settings",
        "base",
        "GENERATE_INFOPLIST_FILE",
    ): "NO",
    (
        "targets",
        "PluginXPCService",
        "settings",
        "base",
        "INFOPLIST_FILE",
    ): "XPCService/Info.plist",
    (
        "targets",
        "AnalysisWorkerXPCService",
        "deploymentTarget",
    ): EXPECTED_DEPLOYMENT_TARGET,
    (
        "targets",
        "AnalysisWorkerXPCService",
        "settings",
        "base",
        "PRODUCT_BUNDLE_IDENTIFIER",
    ): "org.macscope.app.AnalysisWorker",
    (
        "targets",
        "AnalysisWorkerXPCService",
        "settings",
        "base",
        "GENERATE_INFOPLIST_FILE",
    ): "NO",
    (
        "targets",
        "AnalysisWorkerXPCService",
        "settings",
        "base",
        "INFOPLIST_FILE",
    ): "AnalysisWorkerService/Info.plist",
    (
        "targets",
        "AIAgentWorkerXPCService",
        "deploymentTarget",
    ): EXPECTED_DEPLOYMENT_TARGET,
    (
        "targets",
        "AIAgentWorkerXPCService",
        "settings",
        "base",
        "PRODUCT_BUNDLE_IDENTIFIER",
    ): "org.macscope.app.AIAgentWorker",
    (
        "targets",
        "AIAgentWorkerXPCService",
        "settings",
        "base",
        "GENERATE_INFOPLIST_FILE",
    ): "NO",
    (
        "targets",
        "AIAgentWorkerXPCService",
        "settings",
        "base",
        "INFOPLIST_FILE",
    ): "AIAgentWorkerService/Info.plist",
    (
        "targets",
        "NativeDecompilerXPCService",
        "deploymentTarget",
    ): EXPECTED_DEPLOYMENT_TARGET,
    (
        "targets",
        "NativeDecompilerXPCService",
        "settings",
        "base",
        "PRODUCT_BUNDLE_IDENTIFIER",
    ): "org.macscope.app.NativeDecompiler",
    (
        "targets",
        "NativeDecompilerXPCService",
        "settings",
        "base",
        "GENERATE_INFOPLIST_FILE",
    ): "NO",
    (
        "targets",
        "NativeDecompilerXPCService",
        "settings",
        "base",
        "INFOPLIST_FILE",
    ): "NativeDecompilerXPCService/Info.plist",
    (
        "targets",
        "ShellBrokerXPCService",
        "deploymentTarget",
    ): EXPECTED_DEPLOYMENT_TARGET,
    (
        "targets",
        "ShellBrokerXPCService",
        "settings",
        "base",
        "PRODUCT_BUNDLE_IDENTIFIER",
    ): "org.macscope.app.ShellBroker",
    (
        "targets",
        "ShellBrokerXPCService",
        "settings",
        "base",
        "GENERATE_INFOPLIST_FILE",
    ): "NO",
    (
        "targets",
        "ShellBrokerXPCService",
        "settings",
        "base",
        "INFOPLIST_FILE",
    ): "ShellBrokerService/Info.plist",
    (
        "targets",
        "ShellBrokerLaunchAgent",
        "deploymentTarget",
    ): EXPECTED_DEPLOYMENT_TARGET,
    (
        "targets",
        "ShellBrokerLaunchAgent",
        "settings",
        "base",
        "PRODUCT_BUNDLE_IDENTIFIER",
    ): "org.macscope.app.ShellBrokerLaunchAgent",
    ("targets", "SourceExecutionRunner", "deploymentTarget"): EXPECTED_DEPLOYMENT_TARGET,
    ("targets", "SourceExecutionRunner", "settings", "base", "PRODUCT_BUNDLE_IDENTIFIER"): "org.macscope.app.SourceExecutionRunner",
    ("targets", "CoreTests", "deploymentTarget"): EXPECTED_DEPLOYMENT_TARGET,
}

EXPECTED_EFFECTIVE_SETTINGS = {
    "AD_HOC_CODE_SIGNING_ALLOWED": "NO",
    "CODE_SIGNING_ALLOWED": "YES",
    "CODE_SIGNING_REQUIRED": "YES",
    "CODE_SIGN_STYLE": "Manual",
    "CODE_SIGN_IDENTITY": EXPECTED_SIGNER_SUBJECT,
    "DEVELOPMENT_TEAM": "TEAM000000",
    "ENABLE_HARDENED_RUNTIME": "YES",
    "MACOSX_DEPLOYMENT_TARGET": EXPECTED_DEPLOYMENT_TARGET,
    "PRODUCT_BUNDLE_IDENTIFIER": "org.macscope.app",
}

ISOLATED_CI_ENVIRONMENT = {
    "GITHUB_ACTIONS": "true",
    "CI": "true",
    "RUNNER_OS": "macOS",
    "RUNNER_ARCH": "ARM64",
    "MACSCOPE_ISOLATED_CI_ADHOC_SIGNING": "YES",
}

EXPECTED_IDENTIFIERS_BY_TARGET = {
    "MacScopeApp": "org.macscope.app",
    "PluginXPCService": "org.macscope.app.PluginXPCService",
    "AnalysisWorkerXPCService": "org.macscope.app.AnalysisWorker",
    "AIAgentWorkerXPCService": "org.macscope.app.AIAgentWorker",
    "NativeDecompilerXPCService": "org.macscope.app.NativeDecompiler",
    "ShellBrokerXPCService": "org.macscope.app.ShellBroker",
    "ShellBrokerLaunchAgent": "org.macscope.app.ShellBrokerLaunchAgent",
    "SourceExecutionRunner": "org.macscope.app.SourceExecutionRunner",
}

EXPECTED_INFO_PLISTS_BY_TARGET = {
    "MacScopeApp": "Resources/Info.plist",
    "PluginXPCService": "XPCService/Info.plist",
    "AnalysisWorkerXPCService": "AnalysisWorkerService/Info.plist",
    "AIAgentWorkerXPCService": "AIAgentWorkerService/Info.plist",
    "NativeDecompilerXPCService": "NativeDecompilerXPCService/Info.plist",
    "ShellBrokerXPCService": "ShellBrokerService/Info.plist",
    "ShellBrokerLaunchAgent": "ShellBrokerService/LaunchAgentInfo.plist",
    "SourceExecutionRunner": "SourceExecutionRunner/Info.plist",
}

BUILD_PHASE_GUARDED_TARGETS = (
    "MacScopeApp",
    "PluginXPCService",
    "AnalysisWorkerXPCService",
    "AIAgentWorkerXPCService",
    "NativeDecompilerXPCService",
    "ShellBrokerXPCService",
    "ShellBrokerLaunchAgent",
    "SourceExecutionRunner",
)

RELEASE_PROVENANCE_PHASE_NAME = "Generate sealed Release build provenance"
RELEASE_PROVENANCE_OUTPUT = (
    "$(TARGET_BUILD_DIR)/$(UNLOCALIZED_RESOURCES_FOLDER_PATH)/"
    "MacScopeBuildProvenance.json"
)
RELEASE_PROVENANCE_NATIVE_DECOMPILER_INPUT = (
    "$(TARGET_BUILD_DIR)/$(CONTENTS_FOLDER_PATH)/XPCServices/"
    "NativeDecompilerXPCService.xpc/Contents/Resources/"
    "NativeDecompilerBridgeGolden.json"
)
RELEASE_PROVENANCE_NATIVE_DECOMPILER_PACKAGE_ROOT = (
    "$(TARGET_BUILD_DIR)/$(CONTENTS_FOLDER_PATH)/XPCServices/"
    "NativeDecompilerXPCService.xpc/Contents/Resources/NativeDecompilerPackage"
)
RELEASE_PROVENANCE_NATIVE_DECOMPILER_SERVICE_ROOT = (
    "$(TARGET_BUILD_DIR)/$(CONTENTS_FOLDER_PATH)/XPCServices/"
    "NativeDecompilerXPCService.xpc"
)
RELEASE_PROVENANCE_MACHOKIT_INPUT = (
    "$(MACSCOPE_MACHOKIT_MATERIALIZATION_ROOT)/MATERIALIZATION.json"
)
RELEASE_PROVENANCE_GHOSTTY_SURFACE_INPUTS = (
    "$(MACSCOPE_GHOSTTY_SURFACE_MANIFEST)",
    "$(MACSCOPE_GHOSTTY_SURFACE_STAGED_DESCRIPTOR)",
    "$(MACSCOPE_GHOSTTY_SURFACE_ARCHIVE)",
    "$(MACSCOPE_GHOSTTY_SURFACE_HEADER)",
    "$(MACSCOPE_GHOSTTY_SURFACE_MODULE_MAP)",
)
RELEASE_PROVENANCE_ANALYSIS_WORKER_INPUT = (
    "$(TARGET_BUILD_DIR)/$(CONTENTS_FOLDER_PATH)/XPCServices/"
    "AnalysisWorkerXPCService.xpc/Contents/MacOS/AnalysisWorkerXPCService"
)
RELEASE_PROVENANCE_NATIVE_DECOMPILER_INPUTS = (
    RELEASE_PROVENANCE_NATIVE_DECOMPILER_INPUT,
    f"{RELEASE_PROVENANCE_NATIVE_DECOMPILER_PACKAGE_ROOT}/MATERIALIZATION.json",
    f"{RELEASE_PROVENANCE_NATIVE_DECOMPILER_PACKAGE_ROOT}/package",
    f"{RELEASE_PROVENANCE_NATIVE_DECOMPILER_PACKAGE_ROOT}/package/lib/libdecomp.a",
    f"{RELEASE_PROVENANCE_NATIVE_DECOMPILER_PACKAGE_ROOT}/package/lib/libsla.a",
    f"{RELEASE_PROVENANCE_NATIVE_DECOMPILER_SERVICE_ROOT}/Contents/Info.plist",
    (
        f"{RELEASE_PROVENANCE_NATIVE_DECOMPILER_SERVICE_ROOT}/Contents/MacOS/"
        "NativeDecompilerXPCService"
    ),
    f"{RELEASE_PROVENANCE_NATIVE_DECOMPILER_SERVICE_ROOT}/Contents/_CodeSignature/CodeResources",
)
RELEASE_PROVENANCE_COMMAND_LINES = (
    '          /usr/bin/python3 "$SRCROOT/../Scripts/generate_release_build_provenance.py" \\',
    '            --repo-root "$SRCROOT/.." \\',
    '            --project-yml "$SRCROOT/project.yml" \\',
    '            --project-file-path "$PROJECT_FILE_PATH" \\',
    '            --configuration "$CONFIGURATION" \\',
    '            --debug-source-identity "$MACSCOPE_DEBUG_SOURCE_IDENTITY" \\',
    '            --ghostty-source-dir "$SRCROOT/../ThirdParty/GhosttyVT/Source" \\',
    (
        '            --ghostty-surface-manifest '
        '"$MACSCOPE_GHOSTTY_SURFACE_MANIFEST" \\'
    ),
    (
        '            --ghostty-surface-staged-root '
        '"$MACSCOPE_GHOSTTY_SURFACE_STAGED_ROOT" \\'
    ),
    '            --sleigh-materialization-root "$MACSCOPE_SLEIGH_MATERIALIZATION_ROOT" \\',
    '            --machokit-materialization-root "$MACSCOPE_MACHOKIT_MATERIALIZATION_ROOT" \\',
    (
        '            --analysis-worker-executable "$TARGET_BUILD_DIR/'
        '$CONTENTS_FOLDER_PATH/XPCServices/AnalysisWorkerXPCService.xpc/'
        'Contents/MacOS/AnalysisWorkerXPCService" \\'
    ),
    (
        '            --native-decompiler-live-test-condition '
        '"$MACSCOPE_NATIVE_DECOMPILER_LIVE_TEST_CONDITION" \\'
    ),
    '            --swift-active-compilation-conditions "$SWIFT_ACTIVE_COMPILATION_CONDITIONS" \\',
    '            --other-swift-flags "$OTHER_SWIFT_FLAGS" \\',
    '            --architectures "$ARCHS" \\',
    '            --deployment-target "$MACOSX_DEPLOYMENT_TARGET" \\',
    '            --sdk-name "$SDK_NAME" \\',
    '            --sdk-version "$SDK_VERSION" \\',
    '            --sdk-build "$SDK_PRODUCT_BUILD_VERSION" \\',
    '            --developer-dir "$DEVELOPER_DIR" \\',
    (
        '            --swift-executable "$DEVELOPER_DIR/Toolchains/'
        'XcodeDefault.xctoolchain/usr/bin/swiftc" \\'
    ),
    (
        '            --native-decompiler-golden-result "$TARGET_BUILD_DIR/'
        '$CONTENTS_FOLDER_PATH/XPCServices/NativeDecompilerXPCService.xpc/'
        'Contents/Resources/NativeDecompilerBridgeGolden.json" \\'
    ),
    (
        '            --output "$TARGET_BUILD_DIR/'
        '$UNLOCALIZED_RESOURCES_FOLDER_PATH/MacScopeBuildProvenance.json"'
    ),
)
RELEASE_PROVENANCE_GUARD_LINES = (
    '          if [ "$CONFIGURATION" != "Release" ] && [ "$CONFIGURATION" != "Debug" ]; then',
    "            exit 1",
    "          fi",
)
CORETESTS_PROVENANCE_COPY_PHASE_NAME = "Copy sealed provenance into CoreTests"
CORETESTS_PROVENANCE_SOURCE = (
    "$(BUILT_PRODUCTS_DIR)/MacScope.app/Contents/Resources/"
    "MacScopeBuildProvenance.json"
)
CORETESTS_PROVENANCE_DESTINATION = RELEASE_PROVENANCE_OUTPUT
CORETESTS_PROVENANCE_COPY_COMMAND_LINES = (
    "          set -eu",
    *RELEASE_PROVENANCE_GUARD_LINES,
    (
        '          SOURCE="$BUILT_PRODUCTS_DIR/MacScope.app/Contents/Resources/'
        'MacScopeBuildProvenance.json"'
    ),
    (
        '          DESTINATION="$TARGET_BUILD_DIR/'
        '$UNLOCALIZED_RESOURCES_FOLDER_PATH/MacScopeBuildProvenance.json"'
    ),
    '          if [ ! -f "$SOURCE" ] || [ -L "$SOURCE" ]; then',
    '            echo "ERROR: sealed app provenance is missing or is not a regular file" >&2',
    "            exit 1",
    "          fi",
    '          /bin/mkdir -p "$(/usr/bin/dirname "$DESTINATION")"',
    '          TEMPORARY="$(/usr/bin/mktemp "$DESTINATION.tmp.XXXXXX")"',
    '          cleanup() { /bin/rm -f "$TEMPORARY"; }',
    "          trap cleanup 0 1 2 15",
    '          /bin/cp -p "$SOURCE" "$TEMPORARY"',
    '          if [ ! -f "$TEMPORARY" ] || [ -L "$TEMPORARY" ]; then',
    '            echo "ERROR: temporary CoreTests provenance is not a regular file" >&2',
    "            exit 1",
    "          fi",
    '          /usr/bin/cmp -s "$SOURCE" "$TEMPORARY" || {',
    '            echo "ERROR: CoreTests provenance copy changed bytes" >&2',
    "            exit 1",
    "          }",
    '          SOURCE_MODE="$(/usr/bin/stat -f \'%Lp\' "$SOURCE")"',
    '          TEMPORARY_MODE="$(/usr/bin/stat -f \'%Lp\' "$TEMPORARY")"',
    '          if [ "$SOURCE_MODE" != "$TEMPORARY_MODE" ]; then',
    '            echo "ERROR: CoreTests provenance copy changed file mode" >&2',
    "            exit 1",
    "          fi",
    '          /bin/mv -f "$TEMPORARY" "$DESTINATION"',
    "          trap - 0 1 2 15",
    '          if [ ! -f "$DESTINATION" ] || [ -L "$DESTINATION" ]; then',
    '            echo "ERROR: CoreTests provenance destination is not a regular file" >&2',
    "            exit 1",
    "          fi",
    '          /usr/bin/cmp -s "$SOURCE" "$DESTINATION" || {',
    '            echo "ERROR: installed CoreTests provenance changed bytes" >&2',
    "            exit 1",
    "          }",
    '          DESTINATION_MODE="$(/usr/bin/stat -f \'%Lp\' "$DESTINATION")"',
    '          if [ "$SOURCE_MODE" != "$DESTINATION_MODE" ]; then',
    '            echo "ERROR: installed CoreTests provenance changed file mode" >&2',
    "            exit 1",
    "          fi",
)

EXPECTED_INJECT_BASE_ENTITLEMENTS_BY_CONFIGURATION = {
    "Debug": "YES",
    "Release": "YES",
}

EXPECTED_XCODE_TEST_HOST_ENTITLEMENTS = {
    "com.apple.security.get-task-allow": True,
    "com.apple.security.temporary-exception.files.absolute-path.read-only": ["/"],
    "com.apple.security.temporary-exception.mach-lookup.global-name": [
        "com.apple.testmanagerd",
        "com.apple.dt.testmanagerd.runner",
        "com.apple.coresymbolicationd",
    ],
}
EXPECTED_CORETESTS_IDENTIFIER = "org.macscope.app.CoreTests"
EXPECTED_SHELL_BROKER_LAUNCH_AGENT_IDENTIFIER = (
    "org.macscope.app.ShellBrokerLaunchAgent"
)
EXPECTED_RELEASE_SHELL_BROKER_LAUNCH_AGENT_ENTITLEMENTS = {
    "com.apple.application-identifier": (
        f"{EXPECTED_TEAM_IDENTIFIER}.{EXPECTED_SHELL_BROKER_LAUNCH_AGENT_IDENTIFIER}"
    ),
    "com.apple.security.get-task-allow": True,
}
EXPECTED_SHELL_BROKER_LAUNCH_AGENT_ENTITLEMENTS = {
    "com.apple.application-identifier": (
        f"{EXPECTED_TEAM_IDENTIFIER}.{EXPECTED_SHELL_BROKER_LAUNCH_AGENT_IDENTIFIER}"
    ),
    **EXPECTED_XCODE_TEST_HOST_ENTITLEMENTS,
}

EXPECTED_SOURCE_EXECUTION_RUNNER_IDENTIFIER = "org.macscope.app.SourceExecutionRunner"
EXPECTED_RELEASE_SOURCE_EXECUTION_RUNNER_ENTITLEMENTS = {
    "com.apple.application-identifier": f"{EXPECTED_TEAM_IDENTIFIER}.{EXPECTED_SOURCE_EXECUTION_RUNNER_IDENTIFIER}",
    "com.apple.security.get-task-allow": True,
}
EXPECTED_SOURCE_EXECUTION_RUNNER_ENTITLEMENTS = {
    "com.apple.application-identifier": f"{EXPECTED_TEAM_IDENTIFIER}.{EXPECTED_SOURCE_EXECUTION_RUNNER_IDENTIFIER}",
    **EXPECTED_XCODE_TEST_HOST_ENTITLEMENTS,
}

PROFILELESS_BUILD_SETTINGS = (
    "PROVISIONING_PROFILE",
    "PROVISIONING_PROFILE_SPECIFIER",
)

PROTECTED_TARGET_SIGNING_SETTINGS = {
    "AD_HOC_CODE_SIGNING_ALLOWED": "NO",
    "CODE_SIGNING_ALLOWED": "YES",
    "CODE_SIGNING_REQUIRED": "YES",
    "CODE_SIGN_STYLE": "Manual",
    "CODE_SIGN_IDENTITY": "$(MACSCOPE_SIGNING_IDENTITY)",
    "PROVISIONING_PROFILE": "",
    "PROVISIONING_PROFILE_SPECIFIER": "",
    "DEVELOPMENT_TEAM": "$(MACSCOPE_SIGNING_TEAM)",
    "ENABLE_HARDENED_RUNTIME": "YES",
    "MACOSX_DEPLOYMENT_TARGET": EXPECTED_DEPLOYMENT_TARGET,
    "OTHER_CODE_SIGN_FLAGS": "",
}

SENSITIVE_BUILD_SETTINGS = frozenset(
    {
        *PROTECTED_TARGET_SIGNING_SETTINGS,
        "CODE_SIGN_ENTITLEMENTS",
        "CODE_SIGN_INJECT_BASE_ENTITLEMENTS",
        "GENERATE_INFOPLIST_FILE",
        "INFOPLIST_FILE",
        "PRODUCT_BUNDLE_IDENTIFIER",
    }
)

EXPECTED_APP_IDENTIFIER = "org.macscope.app"
EXPECTED_PLUGIN_IDENTIFIER = "org.macscope.app.PluginXPCService"
EXPECTED_WORKER_IDENTIFIER = "org.macscope.app.AnalysisWorker"
EXPECTED_AI_WORKER_IDENTIFIER = "org.macscope.app.AIAgentWorker"
EXPECTED_NATIVE_DECOMPILER_IDENTIFIER = "org.macscope.app.NativeDecompiler"
EXPECTED_SHELL_BROKER_IDENTIFIER = "org.macscope.app.ShellBroker"
EXPECTED_GHOSTTY_VT_IDENTIFIER = "org.macscope.app.GhosttyVT"
EXPECTED_GHOSTTY_VT_DYLIB = "libghostty-vt.dylib"

EXPECTED_EXECUTABLE_BY_IDENTIFIER = {
    EXPECTED_APP_IDENTIFIER: "MacScope",
    EXPECTED_PLUGIN_IDENTIFIER: "PluginXPCService",
    EXPECTED_WORKER_IDENTIFIER: "AnalysisWorkerXPCService",
    EXPECTED_AI_WORKER_IDENTIFIER: "AIAgentWorkerXPCService",
    EXPECTED_NATIVE_DECOMPILER_IDENTIFIER: "NativeDecompilerXPCService",
    EXPECTED_SHELL_BROKER_IDENTIFIER: "ShellBrokerXPCService",
    EXPECTED_CORETESTS_IDENTIFIER: "CoreTests",
}

EXPECTED_RELEASE_XPC_BUNDLES = {
    "AnalysisWorkerXPCService.xpc": (
        "AnalysisWorkerXPCService",
        EXPECTED_WORKER_IDENTIFIER,
    ),
    "AIAgentWorkerXPCService.xpc": (
        "AIAgentWorkerXPCService",
        EXPECTED_AI_WORKER_IDENTIFIER,
    ),
    "NativeDecompilerXPCService.xpc": (
        "NativeDecompilerXPCService",
        EXPECTED_NATIVE_DECOMPILER_IDENTIFIER,
    ),
    "ShellBrokerXPCService.xpc": (
        "ShellBrokerXPCService",
        EXPECTED_SHELL_BROKER_IDENTIFIER,
    ),
}
EXPECTED_RELEASE_MACOS_EXECUTABLES = {
    "MacScope",
    "ShellBrokerLaunchAgent",
    "SourceExecutionRunner",
}
RELEASE_PROVENANCE_RELATIVE_PATH = Path(
    "Contents/Resources/MacScopeBuildProvenance.json"
)
RELEASE_PROVENANCE_MAX_BYTES = 16 * 1024
EXPECTED_RELEASE_PROVENANCE_SCALARS = {
    "schema_version": 1,
    "qualification_eligible": True,
    "configuration": "Release",
    "repository_clean": True,
    "architecture": "arm64",
    "deployment_target": EXPECTED_DEPLOYMENT_TARGET,
    "app_bundle_identifier": EXPECTED_APP_IDENTIFIER,
    "ghostty_surface_compilation_condition": "MACSCOPE_FULL_GHOSTTY_SURFACE",
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
    "ghostty_surface_staged_descriptor_relative_path": (
        "STAGED_GHOSTTY_SURFACE.json"
    ),
    "ghostty_surface_archive_relative_path": "libghostty-internal.a",
    "ghostty_surface_header_relative_path": "Headers/ghostty.h",
    "ghostty_surface_module_map_relative_path": "Headers/module.modulemap",
}
RELEASE_PROVENANCE_SHA256_FIELDS = (
    "selected_build_inputs_sha256",
    "project_yml_sha256",
    "ghostty_surface_source_manifest_sha256",
    "ghostty_surface_build_profile_sha256",
    "ghostty_surface_staged_tree_sha256",
    "ghostty_surface_staged_descriptor_sha256",
    "ghostty_surface_archive_sha256",
    "ghostty_surface_header_sha256",
    "ghostty_surface_module_map_sha256",
    "machokit_analysis_worker_executable_sha256",
    "native_decompiler_embedded_service_executable_sha256",
    "native_decompiler_embedded_service_code_resources_sha256",
)
LOWERCASE_GIT_OID = re.compile(r"^[0-9a-f]{40}$")
LOWERCASE_SHA256 = re.compile(r"^[0-9a-f]{64}$")

ArtifactCommandRunner = Callable[[list[str]], subprocess.CompletedProcess[str]]
XcodeBuildCommandRunner = Callable[[list[str]], subprocess.CompletedProcess[str]]
ToolchainCommandRunner = Callable[
    [list[str], dict[str, str]], subprocess.CompletedProcess[str]
]


def parse_scalar_mapping(yaml_text: str) -> dict[tuple[str, ...], str]:
    """Parse the plain, nested mapping subset used for XcodeGen settings."""
    scalars: dict[tuple[str, ...], str] = {}
    parents: list[tuple[int, str]] = []

    for line in yaml_text.splitlines():
        if not line.strip() or line.lstrip().startswith(("#", "-")):
            continue
        indentation = len(line) - len(line.lstrip(" "))
        content = line[indentation:]
        if content.startswith(("'", '"')):
            quote = content[0]
            closing_quote = content.find(quote, 1)
            if closing_quote < 0 or not content[closing_quote + 1 :].startswith(":"):
                continue
            key = content[1:closing_quote]
            raw_value = content[closing_quote + 2 :].strip()
        else:
            separator = content.find(":")
            if separator <= 0:
                continue
            key = content[:separator].strip()
            raw_value = content[separator + 1 :].strip()
        if not key:
            continue

        while parents and parents[-1][0] >= indentation:
            parents.pop()

        path = tuple(parent_key for _, parent_key in parents) + (key,)
        if not raw_value:
            parents.append((indentation, key))
            continue

        value = raw_value.split(" #", 1)[0].strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in {"'", '"'}:
            value = value[1:-1]
        scalars[path] = value

    return scalars


def parse_xcconfig_assignments(text: str) -> tuple[dict[str, str], list[str]]:
    """Parse the deliberately small assignment/include subset used by MacScope."""
    assignments: dict[str, str] = {}
    errors: list[str] = []
    for line_number, raw_line in enumerate(text.splitlines(), 1):
        line = raw_line.strip()
        if not line or line.startswith("//") or line.startswith("#include"):
            continue
        match = re.fullmatch(r"([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)", line)
        if match is None:
            errors.append(f"xcconfig line {line_number} is not a supported assignment")
            continue
        key, value = match.groups()
        if key in assignments:
            errors.append(f"xcconfig setting {key} is assigned more than once")
            continue
        assignments[key] = value.strip()
    return assignments, errors


def validate_signing_identity_declaration(declaration_text: str) -> list[str]:
    assignments, errors = parse_xcconfig_assignments(declaration_text)
    expected = {
        "MACSCOPE_SIGNING_IDENTITY": EXPECTED_SIGNER_SUBJECT,
        "MACSCOPE_SIGNING_TEAM": EXPECTED_TEAM_IDENTIFIER,
    }
    if assignments != expected:
        errors.append(
            "SigningIdentity.xcconfig must declare exactly the independently approved "
            f"identity/team {expected!r}; observed {assignments!r}"
        )
    includes = [
        line.strip()
        for line in declaration_text.splitlines()
        if line.strip().startswith("#include")
    ]
    if includes:
        errors.append("SigningIdentity.xcconfig must not include another xcconfig")
    return errors


def validate_dependency_roots_config(
    project_text: str,
    dependency_roots_text: str,
) -> list[str]:
    settings = parse_scalar_mapping(project_text)
    errors: list[str] = []
    for configuration in ("Debug", "Release"):
        observed = settings.get(("configFiles", configuration))
        if observed != "DependencyRoots.xcconfig":
            errors.append(
                f"configFiles.{configuration} must be 'DependencyRoots.xcconfig'; "
                f"observed {observed!r}"
            )

    assignments, assignment_errors = parse_xcconfig_assignments(dependency_roots_text)
    errors.extend(assignment_errors)
    expected_roots = {
        "MACSCOPE_SLEIGH_COMPONENT_ROOT": "$(SRCROOT)/../ThirdParty/SleighNative",
        "MACSCOPE_SLEIGH_SOURCE_BUILD_ROOT": "",
        "MACSCOPE_SLEIGH_MATERIALIZATION_ROOT": "",
        "MACSCOPE_MACHOKIT_MATERIALIZATION_ROOT": "$(SRCROOT)/../ThirdParty/MachOKit/materialization",
        "MACSCOPE_GHOSTTY_SURFACE_SOURCE_DIR": "",
        "MACSCOPE_GHOSTTY_SURFACE_ARTIFACT_ROOT": "",
        "MACSCOPE_GHOSTTY_SURFACE_FRAMEWORK": "",
        "MACSCOPE_GHOSTTY_SURFACE_ENABLED": "",
        "MACSCOPE_PARSER_ENGINE_CACHE_ROOT": "",
        "MACSCOPE_PATTERN_ADAPTER_ROOT": "",
    }
    if assignments != expected_roots:
        errors.append(
            "DependencyRoots.xcconfig must assign only authorized repository inputs "
            f"and empty fail-closed generated roots; observed {assignments!r}"
        )
    sensitive = sorted(set(assignments).intersection(SENSITIVE_BUILD_SETTINGS))
    if sensitive:
        errors.append(
            f"DependencyRoots.xcconfig must not assign sensitive build settings: {sensitive!r}"
        )

    includes = [
        line.strip()
        for line in dependency_roots_text.splitlines()
        if line.strip().startswith("#include")
    ]
    expected_includes = [
        '#include "SigningIdentity.xcconfig"',
        '#include? "DependencyRoots.local.xcconfig"',
    ]
    if includes != expected_includes:
        errors.append(
            "DependencyRoots.xcconfig must contain one mandatory SigningIdentity "
            "include followed by one optional DependencyRoots.local include; "
            f"observed {includes!r}"
        )
    return errors


def base_sensitive_setting(key: str) -> str | None:
    base_key = key.split("[", 1)[0]
    return base_key if base_key in SENSITIVE_BUILD_SETTINGS else None


def configuration_for_path(path: tuple[str, ...]) -> str | None:
    try:
        configs_index = path.index("configs")
    except ValueError:
        return None
    if configs_index + 1 >= len(path):
        return None
    return path[configs_index + 1]


INSTALLED_UI_TEST_TARGET = "MacScopeInstalledAppUITests"
INSTALLED_UI_TEST_ENTITLEMENTS = "Tests/MacScopeInstalledAppUITests/InstalledAppUITests.entitlements"
INSTALLED_UI_TEST_ENTITLEMENT_CONTENTS = {
    "com.apple.security.temporary-exception.shared-preference.read-write": ["org.macscope.app"],
}


def validate_installed_ui_test_entitlements(project_directory: Path) -> list[str]:
    label = "installed UI test entitlements"
    path = project_directory / INSTALLED_UI_TEST_ENTITLEMENTS
    try:
        if not project_directory.is_absolute() or project_directory.resolve(strict=True) != project_directory:
            return [f"{label} project directory must be physical and canonical"]
        directories = [project_directory, *list(path.parents)[:2]]
        bindings = []
        for directory in directories:
            metadata = directory.lstat()
            if not stat.S_ISDIR(metadata.st_mode) or stat.S_ISLNK(metadata.st_mode):
                return [f"{label} parent must be a physical directory"]
            bindings.append((metadata.st_dev, metadata.st_ino, metadata.st_mode))
        payload, errors = read_stable_regular_bytes(path, label, 16 * 1024)
        if errors:
            return errors
        observed = plistlib.loads(payload)
        if observed != INSTALLED_UI_TEST_ENTITLEMENT_CONTENTS:
            return [f"{label} must contain only the exact MacScope shared-preference domain exception"]
        for directory, binding in zip(directories, bindings):
            metadata = directory.lstat()
            if (metadata.st_dev, metadata.st_ino, metadata.st_mode) != binding:
                return [f"{label} parent changed during verification"]
    except (OSError, ValueError, plistlib.InvalidFileException) as error:
        return [f"{label} could not be verified: {error}"]
    return []


def validate_project_settings(
    project_text: str, *, project_directory: Path | None = None,
) -> list[str]:
    settings = parse_scalar_mapping(project_text)
    errors: list[str] = []
    for path, expected in EXPECTED_PROJECT_SETTINGS.items():
        observed = settings.get(path)
        if observed != expected:
            errors.append(
                f"{'.'.join(path)} must be {expected!r}; observed {observed!r}"
            )
    for path, observed_value in settings.items():
        setting = path[-1]
        base_setting = base_sensitive_setting(setting)
        if base_setting is not None and setting != base_setting:
            errors.append(
                f"{'.'.join(path)} is a conditional sensitive setting; "
                "conditional signing and identity overrides are prohibited"
            )
            continue
        if setting == "CODE_SIGN_ENTITLEMENTS" and observed_value:
            if path == ("targets", INSTALLED_UI_TEST_TARGET, "settings", "base", "CODE_SIGN_ENTITLEMENTS") and observed_value == INSTALLED_UI_TEST_ENTITLEMENTS:
                errors.extend(validate_installed_ui_test_entitlements(
                    project_directory if project_directory is not None else REPOSITORY_ROOT / "MacScope"
                ))
            else:
                errors.append(
                    f"{'.'.join(path)} must be empty; observed {observed_value!r}"
                )
        if len(path) >= 5 and path[:2] == ("targets", INSTALLED_UI_TEST_TARGET) and "settings" in path[2:-1]:
            ui_expected = PROTECTED_TARGET_SIGNING_SETTINGS.get(setting)
            if setting == "ENABLE_APP_SANDBOX":
                ui_expected = "YES"
            if ui_expected is not None and observed_value != ui_expected:
                errors.append(f"{'.'.join(path)} must inherit or preserve {ui_expected!r}; observed {observed_value!r}")
            if setting.startswith("ENABLE_APP_SANDBOX["):
                errors.append(f"{'.'.join(path)} is a prohibited conditional sandbox override")
        if setting == "OTHER_CODE_SIGN_FLAGS" and observed_value:
            errors.append(
                f"{'.'.join(path)} must be empty; observed {observed_value!r}"
            )
        if setting == "CODE_SIGN_INJECT_BASE_ENTITLEMENTS":
            configuration = configuration_for_path(path)
            expected_injection = EXPECTED_INJECT_BASE_ENTITLEMENTS_BY_CONFIGURATION.get(
                configuration or ""
            )
            if expected_injection is None:
                errors.append(
                    f"{'.'.join(path)} must be declared only for Debug or Release"
                )
            elif observed_value != expected_injection:
                errors.append(
                    f"{'.'.join(path)} must be {expected_injection!r}; "
                    f"observed {observed_value!r}"
                )
        if (
            len(path) >= 5
            and path[0] == "targets"
            and path[1] in EXPECTED_IDENTIFIERS_BY_TARGET
            and "settings" in path[2:-1]
            and path[-1] in PROTECTED_TARGET_SIGNING_SETTINGS
        ):
            expected = PROTECTED_TARGET_SIGNING_SETTINGS[path[-1]]
            if observed_value != expected:
                errors.append(
                    f"{'.'.join(path)} must inherit or preserve {expected!r}; "
                    f"observed {observed_value!r}"
                )
        if (
            len(path) >= 5
            and path[0] == "targets"
            and path[1] in EXPECTED_IDENTIFIERS_BY_TARGET
            and "settings" in path[2:-1]
        ):
            target = path[1]
            target_expected: str | None = None
            if setting == "PRODUCT_BUNDLE_IDENTIFIER":
                target_expected = EXPECTED_IDENTIFIERS_BY_TARGET[target]
            elif setting == "GENERATE_INFOPLIST_FILE":
                target_expected = "NO"
            elif setting == "INFOPLIST_FILE":
                target_expected = EXPECTED_INFO_PLISTS_BY_TARGET[target]
            if target_expected is not None and observed_value != target_expected:
                errors.append(
                    f"{'.'.join(path)} must be {target_expected!r}; "
                    f"observed {observed_value!r}"
                )
    return errors


def validate_app_target_guard(project_text: str) -> list[str]:
    """Require always-run guards on the app and its required embedded worker."""
    lines = project_text.splitlines()
    targets_markers = [
        index for index, line in enumerate(lines) if line == "targets:"
    ]
    if len(targets_markers) != 1:
        return ["project.yml must contain exactly one top-level targets mapping"]
    targets_start = targets_markers[0]
    targets_end = len(lines)
    for index in range(targets_start + 1, len(lines)):
        line = lines[index]
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        if len(line) == len(line.lstrip(" ")):
            targets_end = index
            break
    required_phase = [
        "    preBuildScripts:",
        "      - name: Verify certificate-backed signing environment",
        "        basedOnDependencyAnalysis: false",
        "        script: |",
        (
            '          /usr/bin/python3 "$SRCROOT/../Scripts/'
            'check_local_signing_policy.py" --build-environment '
            '--target "$TARGET_NAME"'
        ),
    ]
    errors: list[str] = []
    for target in BUILD_PHASE_GUARDED_TARGETS:
        target_markers = [
            index
            for index in range(targets_start + 1, targets_end)
            if lines[index] == f"  {target}:"
        ]
        if len(target_markers) != 1:
            errors.append(
                f"project.yml must contain exactly one targets.{target} mapping"
            )
            continue

        target_start = target_markers[0]
        target_end = targets_end
        for index in range(target_start + 1, targets_end):
            line = lines[index]
            if not line.strip() or line.lstrip().startswith("#"):
                continue
            indentation = len(line) - len(line.lstrip(" "))
            if indentation <= 2:
                target_end = index
                break

        if target == "SourceExecutionRunner":
            source_lines = []
            capturing = False
            for line in lines[target_start + 1:target_end]:
                if line == "    sources:":
                    capturing = True
                    continue
                if capturing and line.strip() and len(line) - len(line.lstrip(" ")) <= 4:
                    break
                if capturing and line.strip() and not line.lstrip().startswith("#"):
                    source_lines.append(line)
            if source_lines != ["      - path: SourceExecutionRunner/main.c"]:
                errors.append("SourceExecutionRunner must compile only its fixed main.c source")
        occurrences = 0
        phase_length = len(required_phase)
        for index in range(target_start + 1, target_end - phase_length + 1):
            if lines[index : index + phase_length] == required_phase:
                occurrences += 1
        if occurrences != 1:
            errors.append(
                f"targets.{target} must contain exactly one always-run, target-aware "
                "signing-environment pre-build phase"
            )
    return errors


def target_range(lines: list[str], target: str) -> tuple[int, int] | None:
    targets_markers = [index for index, line in enumerate(lines) if line == "targets:"]
    if len(targets_markers) != 1:
        return None
    targets_start = targets_markers[0]
    targets_end = len(lines)
    for index in range(targets_start + 1, len(lines)):
        line = lines[index]
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        if len(line) == len(line.lstrip(" ")):
            targets_end = index
            break
    markers = [
        index
        for index in range(targets_start + 1, targets_end)
        if lines[index] == f"  {target}:"
    ]
    if len(markers) != 1:
        return None
    start = markers[0]
    end = targets_end
    for index in range(start + 1, targets_end):
        line = lines[index]
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        if len(line) - len(line.lstrip(" ")) <= 2:
            end = index
            break
    return start, end


def validate_release_provenance_project_phase(project_text: str) -> list[str]:
    """Freeze the sole final XcodeGen phase that writes the signed resource."""
    lines = project_text.splitlines()
    app_range = target_range(lines, "MacScopeApp")
    if app_range is None:
        return ["project.yml must contain exactly one MacScopeApp target"]
    start, end = app_range
    expected = [
        f"      - name: {RELEASE_PROVENANCE_PHASE_NAME}",
        "        basedOnDependencyAnalysis: false",
        "        inputFiles:",
        *[
            f'          - "{path}"'
            for path in RELEASE_PROVENANCE_NATIVE_DECOMPILER_INPUTS
        ],
        *[
            f'          - "{path}"'
            for path in RELEASE_PROVENANCE_GHOSTTY_SURFACE_INPUTS
        ],
        f'          - "{RELEASE_PROVENANCE_ANALYSIS_WORKER_INPUT}"',
        f'          - "{RELEASE_PROVENANCE_MACHOKIT_INPUT}"',
        "        outputFiles:",
        f'          - "{RELEASE_PROVENANCE_OUTPUT}"',
        "        script: |",
        *RELEASE_PROVENANCE_GUARD_LINES,
        *RELEASE_PROVENANCE_COMMAND_LINES,
    ]
    occurrences = sum(
        lines[index : index + len(expected)] == expected
        for index in range(start + 1, end - len(expected) + 1)
    )
    errors: list[str] = []
    post_build_markers = [
        index for index in range(start + 1, end) if lines[index] == "    postBuildScripts:"
    ]
    if len(post_build_markers) != 1:
        errors.append("MacScopeApp must contain exactly one postBuildScripts mapping")
    if occurrences != 1:
        errors.append(
            "MacScopeApp must contain exactly one always-run, Debug/Release sealed "
            "provenance post-build phase with the governed command and output"
        )
        return errors
    phase_start = next(
        index
        for index in range(start + 1, end - len(expected) + 1)
        if lines[index : index + len(expected)] == expected
    )
    trailing = [
        line
        for line in lines[phase_start + len(expected) : end]
        if line.strip() and not line.lstrip().startswith("#")
    ]
    if trailing:
        errors.append("MacScopeApp provenance must be its final declared build phase")
    if post_build_markers and post_build_markers[0] >= phase_start:
        errors.append("MacScopeApp provenance must be declared inside its postBuildScripts mapping")
    return errors


def validate_coretests_provenance_copy_project_phase(project_text: str) -> list[str]:
    """Freeze the final dependency-bound copy into the signed CoreTests bundle."""
    lines = project_text.splitlines()
    coretests_range = target_range(lines, "CoreTests")
    if coretests_range is None:
        return ["project.yml must contain exactly one CoreTests target"]
    start, end = coretests_range
    expected = [
        "    postBuildScripts:",
        f"      - name: {CORETESTS_PROVENANCE_COPY_PHASE_NAME}",
        "        basedOnDependencyAnalysis: true",
        "        inputFiles:",
        f'          - "{CORETESTS_PROVENANCE_SOURCE}"',
        "        outputFiles:",
        f'          - "{CORETESTS_PROVENANCE_DESTINATION}"',
        "        script: |",
        *CORETESTS_PROVENANCE_COPY_COMMAND_LINES,
    ]
    occurrences = sum(
        lines[index : index + len(expected)] == expected
        for index in range(start + 1, end - len(expected) + 1)
    )
    errors: list[str] = []
    if occurrences != 1:
        return [
            "CoreTests must contain exactly one dependency-bound, fail-closed sealed "
            "provenance copy phase with the frozen paths and byte/mode checks"
        ]
    phase_start = next(
        index
        for index in range(start + 1, end - len(expected) + 1)
        if lines[index : index + len(expected)] == expected
    )
    trailing = [
        line
        for line in lines[phase_start + len(expected) : end]
        if line.strip() and not line.lstrip().startswith("#")
    ]
    if trailing:
        errors.append("CoreTests provenance copy must be its final declared build phase")
    dependencies = lines[start + 1 : phase_start]
    app_dependency = [
        index
        for index in range(len(dependencies) - 1)
        if dependencies[index] == "    dependencies:"
        and dependencies[index + 1] == "      - target: MacScopeApp"
    ]
    if len(app_dependency) != 1:
        errors.append("CoreTests provenance copy requires one direct MacScopeApp dependency")
    return errors


def pbx_object_blocks(project_text: str) -> list[tuple[str, str, str]]:
    pattern = re.compile(
        r"(?ms)^\t\t([0-9A-F]{24}) /\* (.*?) \*/ = \{\n(.*?)^\t\t\};"
    )
    return [match.groups() for match in pattern.finditer(project_text)]


def validate_provenance_configuration_guard(script: str, *, generation: bool) -> list[str]:
    """Both supported configurations produce receipts; unknown configurations fail closed."""
    expected_prefix = ([] if generation else ["set -eu"]) + [
        line.strip() for line in RELEASE_PROVENANCE_GUARD_LINES
    ]
    lines = [line.strip() for line in script.splitlines() if line.strip()]
    # The generator receives CONFIGURATION once in addition to the two comparisons.
    # An extra configuration branch can silently bypass the required Debug receipt.
    expected_references = 3 if generation else 2
    if (lines[:len(expected_prefix)] != expected_prefix
            or script.count("$CONFIGURATION") != expected_references
            or re.search(r"\bexit\s+0\b", script)):
        return ["provenance phase must admit Debug and Release, reject unknown configurations, and never bypass Debug"]
    return []


def validate_pbx_provenance_configuration_guard(phase_body: str, *, generation: bool) -> list[str]:
    match = re.search(r'(?m)^\s*shellScript = ("(?:[^"\\]|\\.)*");$', phase_body)
    if match is None:
        return ["provenance phase must have a parseable shell script"]
    try:
        script = json.loads(match.group(1))
    except ValueError:
        return ["provenance phase must have a parseable shell script"]
    return validate_provenance_configuration_guard(script, generation=generation)


def validate_generated_provenance_build_phase(project_text: str) -> list[str]:
    """Require the generated phase after every embedded-XPC copy and target-final."""
    blocks = pbx_object_blocks(project_text)
    targets = [
        (identifier, body)
        for identifier, comment, body in blocks
        if comment == "MacScopeApp"
        and "isa = PBXNativeTarget;" in body
        and re.search(r"(?m)^\s*name = MacScopeApp;$", body)
    ]
    phases = [
        (identifier, body)
        for identifier, comment, body in blocks
        if comment == RELEASE_PROVENANCE_PHASE_NAME
        and "isa = PBXShellScriptBuildPhase;" in body
    ]
    errors: list[str] = []
    if len(targets) != 1:
        return ["generated project must contain exactly one MacScopeApp native target"]
    if len(phases) != 1:
        return ["generated project must contain exactly one sealed provenance phase"]
    phase_identifier, phase_body = phases[0]
    errors.extend(validate_pbx_provenance_configuration_guard(phase_body, generation=True))
    build_phases_match = re.search(
        r"(?ms)^\s*buildPhases = \(\n(.*?)^\s*\);",
        targets[0][1],
    )
    if build_phases_match is None:
        return ["generated MacScopeApp target has no parseable buildPhases list"]
    entries = re.findall(
        r"(?m)^\s*([0-9A-F]{24}) /\* (.*?) \*/,$",
        build_phases_match.group(1),
    )
    phase_indices = [
        index for index, (identifier, _) in enumerate(entries) if identifier == phase_identifier
    ]
    if phase_indices != [len(entries) - 1]:
        errors.append("sealed provenance phase must be the final MacScopeApp build phase")

    copy_blocks = {
        identifier: body
        for identifier, _, body in blocks
        if "isa = PBXCopyFilesBuildPhase;" in body
        and 'dstPath = "$(CONTENTS_FOLDER_PATH)/XPCServices";' in body
    }
    copy_indices = [
        index for index, (identifier, _) in enumerate(entries) if identifier in copy_blocks
    ]
    if not copy_indices:
        errors.append("MacScopeApp must copy its embedded XPC services before provenance")
    elif phase_indices and any(index >= phase_indices[0] for index in copy_indices):
        errors.append("sealed provenance phase must follow every embedded-XPC CopyFiles phase")

    input_match = re.search(
        r"(?ms)^\s*inputPaths = \(\n(.*?)^\s*\);",
        phase_body,
    )
    expected_inputs = [
        *RELEASE_PROVENANCE_NATIVE_DECOMPILER_INPUTS,
        *RELEASE_PROVENANCE_GHOSTTY_SURFACE_INPUTS,
        RELEASE_PROVENANCE_ANALYSIS_WORKER_INPUT,
        RELEASE_PROVENANCE_MACHOKIT_INPUT,
    ]
    observed_input_lines = (
        [line.strip() for line in input_match.group(1).splitlines() if line.strip()]
        if input_match is not None
        else []
    )
    expected_input_lines = [f'"{path}",' for path in expected_inputs]
    if observed_input_lines != expected_input_lines:
        errors.append(
            "generated sealed provenance phase must have the exact ordered input "
            "inventory, including all five Ghostty staged-surface inputs"
        )

    output_match = re.search(
        r"(?ms)^\s*outputPaths = \(\n(.*?)^\s*\);",
        phase_body,
    )
    observed_output_lines = (
        [line.strip() for line in output_match.group(1).splitlines() if line.strip()]
        if output_match is not None
        else []
    )
    if observed_output_lines != [f'"{RELEASE_PROVENANCE_OUTPUT}",']:
        errors.append("generated sealed provenance phase must have the exact output")

    required_phase_fragments = (
        "alwaysOutOfDate = 1;",
        f'name = "{RELEASE_PROVENANCE_PHASE_NAME}";',
        *[
            f'"{path}",'
            for path in RELEASE_PROVENANCE_NATIVE_DECOMPILER_INPUTS
        ],
        *[
            f'"{path}",'
            for path in RELEASE_PROVENANCE_GHOSTTY_SURFACE_INPUTS
        ],
        f'"{RELEASE_PROVENANCE_ANALYSIS_WORKER_INPUT}",',
        f'"{RELEASE_PROVENANCE_MACHOKIT_INPUT}",',
        f'"{RELEASE_PROVENANCE_OUTPUT}",',
        "generate_release_build_provenance.py",
        "--project-file-path",
        "$PROJECT_FILE_PATH",
        '--developer-dir \\"$DEVELOPER_DIR\\"',
        (
            '--swift-executable \\"$DEVELOPER_DIR/Toolchains/'
            'XcodeDefault.xctoolchain/usr/bin/swiftc\\"'
        ),
        (
            '--native-decompiler-golden-result \\"$TARGET_BUILD_DIR/'
            '$CONTENTS_FOLDER_PATH/XPCServices/NativeDecompilerXPCService.xpc/'
            'Contents/Resources/NativeDecompilerBridgeGolden.json\\"'
        ),
        '--machokit-materialization-root \\"$MACSCOPE_MACHOKIT_MATERIALIZATION_ROOT\\"',
        (
            '--analysis-worker-executable \\"$TARGET_BUILD_DIR/'
            '$CONTENTS_FOLDER_PATH/XPCServices/AnalysisWorkerXPCService.xpc/'
            'Contents/MacOS/AnalysisWorkerXPCService\\"'
        ),
        '--ghostty-surface-manifest \\"$MACSCOPE_GHOSTTY_SURFACE_MANIFEST\\"',
        '--ghostty-surface-staged-root \\"$MACSCOPE_GHOSTTY_SURFACE_STAGED_ROOT\\"',
    )
    for fragment in required_phase_fragments:
        if phase_body.count(fragment) != 1:
            errors.append(
                f"generated sealed provenance phase must contain exactly one {fragment!r}"
            )
    surface_cli_bindings = re.findall(
        r"--ghostty-surface-[a-z-]+",
        phase_body,
    )
    if surface_cli_bindings != [
        "--ghostty-surface-manifest",
        "--ghostty-surface-staged-root",
    ]:
        errors.append(
            "generated sealed provenance phase must contain exactly the two ordered "
            "Ghostty surface CLI bindings"
        )
    return errors


def validate_generated_coretests_provenance_copy_phase(project_text: str) -> list[str]:
    """Require the signed-test resource copy after its app dependency and target-final."""
    blocks = pbx_object_blocks(project_text)
    app_targets = [
        (identifier, body)
        for identifier, comment, body in blocks
        if comment == "MacScopeApp"
        and "isa = PBXNativeTarget;" in body
        and re.search(r"(?m)^\s*name = MacScopeApp;$", body)
    ]
    core_targets = [
        (identifier, body)
        for identifier, comment, body in blocks
        if comment == "CoreTests"
        and "isa = PBXNativeTarget;" in body
        and re.search(r"(?m)^\s*name = CoreTests;$", body)
    ]
    phases = [
        (identifier, body)
        for identifier, comment, body in blocks
        if comment == CORETESTS_PROVENANCE_COPY_PHASE_NAME
        and "isa = PBXShellScriptBuildPhase;" in body
    ]
    if len(app_targets) != 1:
        return ["generated project must contain exactly one MacScopeApp native target"]
    if len(core_targets) != 1:
        return ["generated project must contain exactly one CoreTests native target"]
    if len(phases) != 1:
        return ["generated project must contain exactly one CoreTests provenance copy phase"]
    errors: list[str] = []
    phase_identifier, phase_body = phases[0]
    errors.extend(validate_pbx_provenance_configuration_guard(phase_body, generation=False))
    core_body = core_targets[0][1]
    build_phases_match = re.search(
        r"(?ms)^\s*buildPhases = \(\n(.*?)^\s*\);",
        core_body,
    )
    if build_phases_match is None:
        return ["generated CoreTests target has no parseable buildPhases list"]
    phase_entries = re.findall(
        r"(?m)^\s*([0-9A-F]{24}) /\* (.*?) \*/,$",
        build_phases_match.group(1),
    )
    phase_indices = [
        index
        for index, (identifier, _) in enumerate(phase_entries)
        if identifier == phase_identifier
    ]
    if phase_indices != [len(phase_entries) - 1]:
        errors.append("CoreTests provenance copy must be its final generated build phase")

    dependency_match = re.search(
        r"(?ms)^\s*dependencies = \(\n(.*?)^\s*\);",
        core_body,
    )
    dependency_ids = (
        re.findall(
            r"(?m)^\s*([0-9A-F]{24}) /\* PBXTargetDependency \*/,$",
            dependency_match.group(1),
        )
        if dependency_match is not None
        else []
    )
    app_identifier = app_targets[0][0]
    dependency_blocks = {
        identifier: body
        for identifier, _, body in blocks
        if "isa = PBXTargetDependency;" in body
    }
    app_dependencies = [
        identifier
        for identifier in dependency_ids
        if identifier in dependency_blocks
        and re.search(
            rf"(?m)^\s*target = {re.escape(app_identifier)} /\* MacScopeApp \*/;$",
            dependency_blocks[identifier],
        )
    ]
    if len(app_dependencies) != 1:
        errors.append("generated CoreTests must directly depend on MacScopeApp")

    input_match = re.search(
        r"(?ms)^\s*inputPaths = \(\n(.*?)^\s*\);",
        phase_body,
    )
    output_match = re.search(
        r"(?ms)^\s*outputPaths = \(\n(.*?)^\s*\);",
        phase_body,
    )
    expected_input = f'"{CORETESTS_PROVENANCE_SOURCE}",'
    expected_output = f'"{CORETESTS_PROVENANCE_DESTINATION}",'
    if input_match is None or input_match.group(1).strip() != expected_input:
        errors.append("generated CoreTests provenance copy must have the exact app input")
    if output_match is None or output_match.group(1).strip() != expected_output:
        errors.append("generated CoreTests provenance copy must have the exact bundle output")
    if "alwaysOutOfDate = 1;" in phase_body:
        errors.append(
            "generated CoreTests provenance copy must use its complete input/output graph"
        )
    required_fragments = (
        f'name = "{CORETESTS_PROVENANCE_COPY_PHASE_NAME}";',
        "$BUILT_PRODUCTS_DIR/MacScope.app/Contents/Resources/"
        "MacScopeBuildProvenance.json",
        "/bin/cp -p",
        "/usr/bin/cmp -s",
        "/usr/bin/stat -f",
        "[ -L",
    )
    for fragment in required_fragments:
        if fragment not in phase_body:
            errors.append(
                f"generated CoreTests provenance copy must contain {fragment!r}"
            )
    return errors


def validate_json_provenance_phases(project: dict) -> list[str]:
    """Validate the same provenance invariants against native JSON phase objects."""
    targets = project.get("targets")
    if not isinstance(targets, list) or any(not isinstance(t, dict) for t in targets):
        return ["generated JSON project must have a target list"]
    if any(not isinstance(target.get("build-phases", []), list) for target in targets):
        return ["generated JSON target build-phases must be an array"]
    errors: list[str] = []
    selected = {}
    for name in ("MacScopeApp", "CoreTests"):
        matches = [target for target in targets if target.get("name") == name]
        if len(matches) != 1:
            return [f"generated project must contain exactly one {name} native target"]
        expected_type = "application" if name == "MacScopeApp" else "bundle.unit-test"
        if matches[0].get("product-type") != expected_type:
            return [f"generated {name} must have product-type {expected_type}"]
        selected[name] = matches[0]
    phases = {}
    for target_name, phase_name in (
        ("MacScopeApp", RELEASE_PROVENANCE_PHASE_NAME),
        ("CoreTests", CORETESTS_PROVENANCE_COPY_PHASE_NAME),
    ):
        entries = selected[target_name].get("build-phases")
        if not isinstance(entries, list):
            return [f"generated {target_name} target has no parseable build-phases list"]
        matches = [(index, phase) for index, phase in enumerate(entries)
                   if isinstance(phase, dict) and phase.get("kind") == "script"
                   and phase.get("name") == phase_name]
        all_matches = [phase for target in targets
                       for phase in target.get("build-phases", [])
                       if isinstance(phase, dict) and phase.get("name") == phase_name]
        if len(matches) != 1 or len(all_matches) != 1:
            return [f"generated project must contain exactly one {phase_name} phase"]
        index, phase = matches[0]
        phases[target_name] = phase
        if index != len(entries) - 1:
            errors.append(f"{phase_name} must be the final {target_name} build phase")
        if target_name == "MacScopeApp":
            if phase.get("run-on-every-build") is not True:
                errors.append(f"{phase_name} must run on every build")
        elif phase.get("run-on-every-build", False) is not False:
            errors.append("generated CoreTests provenance copy must use its complete input/output graph")
        script = phase.get("script")
        if isinstance(script, list) and all(isinstance(line, str) for line in script):
            script = "\n".join(script)
        if not isinstance(script, str):
            return [f"{phase_name} must have a script string or string array"]
        phases[target_name] = (phase, script)
        errors.extend(validate_provenance_configuration_guard(
            script, generation=target_name == "MacScopeApp"
        ))
        if target_name == "MacScopeApp":
            copies = [i for i, item in enumerate(entries) if isinstance(item, dict)
                      and item.get("kind") == "copy"
                      and item.get("relative-path") == "$(CONTENTS_FOLDER_PATH)/XPCServices"]
            if not copies:
                errors.append("MacScopeApp must copy its embedded XPC services before provenance")
            elif any(i >= index for i in copies):
                errors.append("sealed provenance phase must follow every embedded-XPC CopyFiles phase")
    dependencies = selected["CoreTests"].get("dependencies", [])
    if not isinstance(dependencies, list) or dependencies.count("MacScopeApp") != 1:
        errors.append("generated CoreTests must directly depend on MacScopeApp")
    phase, script = phases["MacScopeApp"]
    inputs = phase.get("input-paths", [])
    outputs = phase.get("output-paths", [])
    if not isinstance(inputs, list) or not isinstance(outputs, list):
        return errors + ["sealed provenance paths must be arrays"]
    expected_inputs = [
        *RELEASE_PROVENANCE_NATIVE_DECOMPILER_INPUTS,
        *RELEASE_PROVENANCE_GHOSTTY_SURFACE_INPUTS,
        RELEASE_PROVENANCE_ANALYSIS_WORKER_INPUT,
        RELEASE_PROVENANCE_MACHOKIT_INPUT,
    ]
    if inputs != expected_inputs:
        errors.append(
            "generated sealed provenance phase must have the exact ordered input "
            "inventory, including all five Ghostty staged-surface inputs"
        )
    if outputs != [RELEASE_PROVENANCE_OUTPUT]:
        errors.append("generated sealed provenance phase must have the exact output")
    fragments = (
        "generate_release_build_provenance.py", "--project-file-path", "$PROJECT_FILE_PATH",
        '--developer-dir "$DEVELOPER_DIR"',
        '--swift-executable "$DEVELOPER_DIR/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc"',
        '--native-decompiler-golden-result "$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/XPCServices/NativeDecompilerXPCService.xpc/Contents/Resources/NativeDecompilerBridgeGolden.json"',
        '--machokit-materialization-root "$MACSCOPE_MACHOKIT_MATERIALIZATION_ROOT"',
        '--analysis-worker-executable "$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/XPCServices/AnalysisWorkerXPCService.xpc/Contents/MacOS/AnalysisWorkerXPCService"',
        '--ghostty-surface-manifest "$MACSCOPE_GHOSTTY_SURFACE_MANIFEST"',
        '--ghostty-surface-staged-root "$MACSCOPE_GHOSTTY_SURFACE_STAGED_ROOT"',
    )
    for fragment in fragments:
        if script.count(fragment) != 1:
            errors.append(f"generated sealed provenance phase must contain exactly one {fragment!r}")
    if re.findall(r"--ghostty-surface-[a-z-]+", script) != [
        "--ghostty-surface-manifest", "--ghostty-surface-staged-root",
    ]:
        errors.append(
            "generated sealed provenance phase must contain exactly the two ordered "
            "Ghostty surface CLI bindings"
        )
    phase, script = phases["CoreTests"]
    if phase.get("input-paths") != [CORETESTS_PROVENANCE_SOURCE]:
        errors.append("generated CoreTests provenance copy must have the exact app input")
    if phase.get("output-paths") != [CORETESTS_PROVENANCE_DESTINATION]:
        errors.append("generated CoreTests provenance copy must have the exact bundle output")
    for fragment in (
        "$BUILT_PRODUCTS_DIR/MacScope.app/Contents/Resources/MacScopeBuildProvenance.json",
        "/bin/cp -p", "/usr/bin/cmp -s", "/usr/bin/stat -f", "[ -L",
    ):
        if fragment not in script:
            errors.append(f"generated CoreTests provenance copy must contain {fragment!r}")
    return errors


def validate_generated_project_provenance_phase(xcodeproj: Path) -> list[str]:
    project_file = xcodeproj / "project.xcproj"
    if project_file.exists():
        if (xcodeproj / "project.pbxproj").exists() or (xcodeproj / "project.pbxproj").is_symlink():
            return ["generated project must not contain both project formats"]
        try:
            return validate_json_provenance_phases(read_project(project_file))
        except (OSError, UnicodeError, ValueError, TypeError) as error:
            return [f"generated JSON project provenance phase could not be read: {error}"]
    return ["generated project must contain the authoritative JSON project.xcproj"]


def xcodebuild_command_blocks(workflow_text: str) -> list[list[str]]:
    lines = workflow_text.splitlines()
    blocks: list[list[str]] = []
    index = 0
    while index < len(lines):
        if not lines[index].strip().startswith("xcodebuild"):
            index += 1
            continue

        block = [lines[index].strip()]
        while block[-1].endswith("\\") and index + 1 < len(lines):
            index += 1
            block.append(lines[index].strip())
        blocks.append([line.removesuffix("\\").rstrip() for line in block])
        index += 1
    return blocks


def direct_block_range(
    lines: list[str], start: int, end: int, marker: str
) -> tuple[int, int] | None:
    """Locate one exact YAML block marker within an already bounded parent."""
    markers = [index for index in range(start, end) if lines[index] == marker]
    if len(markers) != 1:
        return None
    marker_index = markers[0]
    marker_indentation = len(marker) - len(marker.lstrip(" "))
    block_end = end
    for index in range(marker_index + 1, end):
        line = lines[index]
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        indentation = len(line) - len(line.lstrip(" "))
        if indentation <= marker_indentation:
            block_end = index
            break
    return marker_index, block_end


def ci_test_run_script(workflow_text: str) -> str | None:
    """Return the enabled jobs.test Build-and-test script from self-hosted CI."""
    lines = workflow_text.splitlines()
    jobs_range = direct_block_range(lines, 0, len(lines), "jobs:")
    if jobs_range is None:
        return None
    test_range = direct_block_range(lines, jobs_range[0] + 1, jobs_range[1], "  test:")
    if test_range is None:
        return None
    job_conditions = [
        line
        for line in lines[test_range[0] + 1 : test_range[1]]
        if line.startswith("    if:")
    ]
    # This one condition protects the personal runner without disabling its
    # canonical push/dispatch and same-repository PR qualification gates.
    permitted_condition = (
        "    if: github.event_name != 'pull_request' || "
        "github.event.pull_request.head.repo.full_name == github.repository"
    )
    if job_conditions != [permitted_condition]:
        return None
    steps_range = direct_block_range(
        lines, test_range[0] + 1, test_range[1], "    steps:"
    )
    if steps_range is None:
        return None
    step_range = direct_block_range(
        lines,
        steps_range[0] + 1,
        steps_range[1],
        "      - name: Build and test",
    )
    if step_range is None:
        return None
    if any(
        line.startswith("        if:")
        for line in lines[step_range[0] + 1 : step_range[1]]
    ):
        return None
    run_marker = "        run: |"
    run_markers = [
        index
        for index in range(step_range[0] + 1, step_range[1])
        if lines[index] == run_marker
    ]
    if len(run_markers) != 1:
        return None
    content_indentation = 10
    content: list[str] = []
    for line in lines[run_markers[0] + 1 : step_range[1]]:
        if not line.strip():
            content.append("")
            continue
        if not line.startswith(" " * content_indentation):
            return None
        content.append(line[content_indentation:])
    return "\n".join(content)


def validate_isolated_ci_signing_branch(qualifier_text: str) -> list[str]:
    """Freeze the optional ad-hoc qualifier mode independently of CI policy."""
    marker = 'if [[ "${SIGNING}" == "isolated-ci" ]]; then'
    marker_index = qualifier_text.find(marker)
    if marker_index < 0:
        return ["qualification entrypoint lacks an isolated-CI signing branch"]
    branch_end = qualifier_text.find("\nfi", marker_index)
    if branch_end < 0:
        return ["qualification entrypoint isolated-CI signing branch is malformed"]
    signing_branch = qualifier_text[marker_index:branch_end]
    required_signing_fragments = (
        "AD_HOC_CODE_SIGNING_ALLOWED=YES",
        "CODE_SIGN_STYLE=Manual",
        "CODE_SIGN_IDENTITY=-",
        "ENABLE_HARDENED_RUNTIME=YES",
        "DEVELOPMENT_TEAM=",
        "MACSCOPE_ISOLATED_CI_ADHOC_SIGNING=YES",
    )
    qualifier_lines = [line.strip() for line in qualifier_text.splitlines()]
    signing_lines = [line.strip() for line in signing_branch.splitlines()]
    if any(
        qualifier_lines.count(fragment) != 1 or signing_lines.count(fragment) != 1
        for fragment in required_signing_fragments
    ):
        return [
            "the isolated-CI qualification branch must explicitly set ad-hoc manual "
            "signing, hardened runtime, empty team, and the isolated-CI opt-in"
        ]
    return []


CI_RELEASE_CANDIDATE_RUN_LINE = '--release-candidate "$MACSCOPE_RELEASE_CANDIDATE" \\'
CI_RELEASE_CANDIDATE_ENVIRONMENT_LINE = (
    "      MACSCOPE_RELEASE_CANDIDATE: ${{ github.event_name == 'schedule' "
    "&& 'skip' || 'build' }}"
)


def validate_ci_release_candidate_policy(
    workflow_text: str,
    executable_lines: list[str],
) -> list[str]:
    """Only the nightly schedule may skip the Release candidate.

    Without the option the qualifier always builds it. With it, the value must
    come from the one job-level expression that yields build for manual
    dispatch, and nothing else in the workflow may name or override it.
    """
    release_lines = [
        line for line in executable_lines if line.startswith("--release-candidate")
    ]
    if not release_lines:
        return []
    if (
        release_lines != [CI_RELEASE_CANDIDATE_RUN_LINE]
        or workflow_text.splitlines().count(CI_RELEASE_CANDIDATE_ENVIRONMENT_LINE) != 1
        or workflow_text.count("MACSCOPE_RELEASE_CANDIDATE") != 2
    ):
        return [
            "self-hosted CI may skip the Release candidate only through the pinned "
            "MACSCOPE_RELEASE_CANDIDATE expression: manual dispatch must build it, "
            "and only the nightly schedule may skip it"
        ]
    return []


def validate_ci_runner_work_roots(workflow_text: str) -> bool:
    """Require the guarded runner-root exports, each exactly once."""
    guard = ': "${MACSCOPE_WORK_ROOT:?set MACSCOPE_WORK_ROOT in the runner .env file}"'
    roots = {
        "MACSCOPE_CI_QUALIFICATION_ROOT": "MacScopeCIQualificationRuns",
        "MACSCOPE_DEPENDENCY_CACHE_ROOT": "MacScopeQualificationCache-20260920",
        "MACSCOPE_PATTERN_ADAPTER_ROOT": "MacScopeQualificationCache-20260920/pattern-adapter/ea4b6adacad1188f",
        "MACSCOPE_PATTERN_ADAPTER_RECEIPT": "MacScopeQualificationCache-20260920/pattern-adapter/ea4b6adacad1188f/PRODUCER_RECEIPT.md",
    }
    exports = [
        f'  echo "{name}=$MACSCOPE_WORK_ROOT/{suffix}"'
        for name, suffix in roots.items()
    ]
    block = "\n".join("          " + line for line in
                      [guard, "{", *exports, '} >> "$GITHUB_ENV"'])
    if workflow_text.count(block) != 1 or workflow_text.count(guard) != 1:
        return False
    # Bind the literal block to the first, unconditional Bash step. A matching
    # block in a skipped step or inert shell text is not an executed export.
    lines = workflow_text.splitlines()
    parent = direct_block_range(lines, 0, len(lines), "jobs:")
    for marker in ("  test:", "    steps:"):
        if parent is None:
            return False
        parent = direct_block_range(lines, parent[0] + 1, parent[1], marker)
    if parent is None:
        return False
    step_marker = "      - name: Clear stale sparse checkout from the reused workspace"
    first = next((line for line in lines[parent[0] + 1:parent[1]]
                  if line.strip() and not line.lstrip().startswith("#")), None)
    if first != step_marker:
        return False
    step = direct_block_range(lines, parent[0] + 1, parent[1], step_marker)
    if step is None:
        return False
    body = lines[step[0] + 1:step[1]]
    try:
        run_index = body.index("        run: |")
    except ValueError:
        return False
    metadata = [line.strip() for line in body[:run_index]
                if line.strip() and not line.lstrip().startswith("#")]
    if metadata != ["shell: bash"]:
        return False
    script = body[run_index + 1:]
    if any(line.strip() and not line.startswith("          ") for line in script):
        return False
    executable = [line for line in script
                  if line.strip() and not line.lstrip().startswith("#")]
    if executable[:len(block.splitlines())] != block.splitlines():
        return False
    # YAML permits quoted keys; the shell permits a quoted name adjacent to '='.
    # Neither spelling may conceal a second assignment to a governed root.
    return all(len(re.findall(rf"\b{name}[\"']?\s*[:=]", workflow_text)) == 1
               for name in roots)


def validate_ci_override(
    workflow_text: str,
    qualifier_text: str | None = None,
) -> list[str]:
    run_script = ci_test_run_script(workflow_text)
    if run_script is None:
        return ["self-hosted CI must contain one literal Build and test run script"]

    executable_lines = [
        line.strip()
        for line in run_script.splitlines()
        if line.strip() and not line.lstrip().startswith("#")
    ]
    if not executable_lines or executable_lines[0] != (
        "./Scripts/qualify_local_private_build.sh \\"
    ):
        return [
            "the Build and test step must execute the guarded local qualification "
            "entrypoint directly, before any other shell command"
        ]
    required_run_fragments = (
        '--source-root "$GITHUB_WORKSPACE" \\',
        '--work-root "$MACSCOPE_CI_QUALIFICATION_ROOT/$MACSCOPE_QUALIFICATION_WORK_ROOT_NAME" \\',
        '--dependency-cache-root "$MACSCOPE_DEPENDENCY_CACHE_ROOT" \\',
        "${MACSCOPE_CI_SELECTION} \\",
        "--signing development > xcodebuild.log 2>&1 || { tail -400 xcodebuild.log; exit 1; }",
    )
    # D9: one persistent warm work root, not a run-unique one.
    required_work_root = (
        "MACSCOPE_QUALIFICATION_WORK_ROOT_NAME: macscope-qualification-nightly"
    )
    if (
        any(run_script.count(fragment) != 1 for fragment in required_run_fragments)
        or workflow_text.count(required_work_root) != 1
        or not validate_ci_runner_work_roots(workflow_text)
    ):
        return [
            "the self-hosted qualification command must use the checked-out source, "
            "persistent warm Developer work root, the path-selected test "
            "arguments, and certificate-backed development signing"
        ]
    release_errors = validate_ci_release_candidate_policy(workflow_text, executable_lines)
    if release_errors:
        return release_errors
    if (
        re.search(r"(?m)^\s*(?:/usr/bin/)?xcodebuild(?:\s|\\)", run_script)
        or "materialize_" in run_script
        or "--materialize-dependencies" in run_script
    ):
        return [
            "self-hosted CI must not bypass the qualification entrypoint with direct "
            "Xcode or materializer orchestration"
        ]

    if qualifier_text is None:
        qualifier_path = Path(__file__).resolve().parent / "qualify_local_private_build.sh"
        try:
            qualifier_text = qualifier_path.read_text(encoding="utf-8")
        except (OSError, UnicodeError) as error:
            return [f"qualification entrypoint could not be read: {error}"]
    return validate_isolated_ci_signing_branch(qualifier_text)


def parse_target_build_settings(output: str, target: str) -> dict[str, str]:
    header = f"Build settings for action build and target {target}:"
    settings: dict[str, str] = {}
    in_target_block = False
    for line in output.splitlines():
        if line.strip() == header:
            in_target_block = True
            continue
        if in_target_block and line.startswith("Build settings for action "):
            break
        if not in_target_block:
            continue
        match = re.match(r"^\s+(.+?)\s+=\s*(.*?)\s*$", line)
        if match is not None:
            key = match.group(1).strip()
            if len(key) >= 2 and key[0] == key[-1] and key[0] in {"'", '"'}:
                key = key[1:-1]
            settings[key] = match.group(2)
    return settings


def validate_effective_settings(
    output: str,
    configuration: str,
    target: str = "MacScopeApp",
) -> list[str]:
    settings = parse_target_build_settings(output, target)
    return validate_effective_settings_values(settings, configuration, target)


def validate_effective_settings_values(
    settings: dict[str, str], configuration: str, target: str,
) -> list[str]:
    """Apply the same signing policy to text and structured Xcode settings."""
    expected = dict(EXPECTED_EFFECTIVE_SETTINGS)
    expected["PRODUCT_BUNDLE_IDENTIFIER"] = EXPECTED_IDENTIFIERS_BY_TARGET[target]
    expected["GENERATE_INFOPLIST_FILE"] = "NO"
    expected["INFOPLIST_FILE"] = EXPECTED_INFO_PLISTS_BY_TARGET[target]
    expected["CODE_SIGN_INJECT_BASE_ENTITLEMENTS"] = (
        EXPECTED_INJECT_BASE_ENTITLEMENTS_BY_CONFIGURATION[configuration]
    )

    errors: list[str] = []
    for setting in settings:
        base_setting = base_sensitive_setting(setting)
        if base_setting is not None and setting != base_setting:
            errors.append(
                f"{configuration} {target} contains conditional sensitive setting "
                f"{setting!r}"
            )
    for key, expected_value in expected.items():
        observed = settings.get(key)
        if observed != expected_value:
            errors.append(
                f"{configuration} {target} {key} must be {expected_value!r}; "
                f"observed {observed!r}"
            )
    for key in PROFILELESS_BUILD_SETTINGS:
        observed = settings.get(key, "")
        if observed:
            errors.append(
                f"{configuration} {target} {key} must be empty or omitted; "
                f"observed {observed!r}"
            )
    authored_entitlements = settings.get("CODE_SIGN_ENTITLEMENTS", "")
    if authored_entitlements:
        errors.append(
            f"{configuration} {target} CODE_SIGN_ENTITLEMENTS must be empty; "
            f"observed {authored_entitlements!r}"
        )
    other_code_sign_flags = settings.get("OTHER_CODE_SIGN_FLAGS", "")
    if other_code_sign_flags:
        errors.append(
            f"{configuration} {target} OTHER_CODE_SIGN_FLAGS must be empty; "
            f"observed {other_code_sign_flags!r}"
        )
    return errors


def validate_build_environment(
    environment: dict[str, str],
    target: str | None = None,
) -> list[str]:
    selected_target = target or environment.get("TARGET_NAME") or "MacScopeApp"
    if selected_target not in EXPECTED_IDENTIFIERS_BY_TARGET:
        return [
            "active build TARGET_NAME must be one of "
            f"{sorted(EXPECTED_IDENTIFIERS_BY_TARGET)!r}; observed {selected_target!r}"
        ]
    expected = dict(EXPECTED_EFFECTIVE_SETTINGS)
    expected["PRODUCT_BUNDLE_IDENTIFIER"] = EXPECTED_IDENTIFIERS_BY_TARGET[
        selected_target
    ]
    expected["GENERATE_INFOPLIST_FILE"] = "NO"
    expected["INFOPLIST_FILE"] = EXPECTED_INFO_PLISTS_BY_TARGET[selected_target]
    scope = "active local build"
    errors: list[str] = []
    environment_target = environment.get("TARGET_NAME")
    if environment_target is not None and environment_target != selected_target:
        errors.append(
            f"active build TARGET_NAME must match guarded target {selected_target!r}; "
            f"observed {environment_target!r}"
        )
    for setting in environment:
        base_setting = base_sensitive_setting(setting)
        if base_setting is not None and setting != base_setting:
            errors.append(
                f"active build contains conditional sensitive setting {setting!r}"
            )
    # Explicit local iteration only. Persistent Debug/Release settings remain
    # certificate-backed; this opt-in never admits archive/install or CI use.
    unsigned_development = "MACSCOPE_DEV_UNSIGNED" in environment
    if unsigned_development:
        required = {
            "MACSCOPE_DEV_UNSIGNED": "YES",
            "CONFIGURATION": "Debug", "ACTION": "build",
            "MACSCOPE_DEBUG_SOURCE_IDENTITY": "runtime-only",
            "CODE_SIGNING_ALLOWED": "NO", "CODE_SIGNING_REQUIRED": "NO",
            "AD_HOC_CODE_SIGNING_ALLOWED": "NO",
        }
        for key, value in required.items():
            if environment.get(key) != value:
                errors.append(f"unsigned development {key} must be {value!r}")
        for key in ("CODE_SIGN_IDENTITY", "EXPANDED_CODE_SIGN_IDENTITY", "DEVELOPMENT_TEAM"):
            if environment.get(key, ""):
                errors.append(f"unsigned development {key} must be empty or omitted")
        if any(environment.get(key) for key in ("CI", "GITHUB_ACTIONS", "MACSCOPE_ISOLATED_CI_ADHOC_SIGNING", "MACSCOPE_NATIVE_RELEASE_ADMISSION")):
            errors.append("unsigned development cannot be used by CI or release qualification")
        scope = "active unsigned development build"
        expected.update({"CODE_SIGNING_ALLOWED": "NO", "CODE_SIGNING_REQUIRED": "NO"})
        expected.pop("CODE_SIGN_IDENTITY")
        expected.pop("DEVELOPMENT_TEAM")
    ci_opt_in_present = "MACSCOPE_ISOLATED_CI_ADHOC_SIGNING" in environment
    ci_environment_matches = all(
        environment.get(key) == value
        for key, value in ISOLATED_CI_ENVIRONMENT.items()
    )
    if ci_opt_in_present:
        for key, expected_value in ISOLATED_CI_ENVIRONMENT.items():
            observed = environment.get(key)
            if observed != expected_value:
                errors.append(
                    f"active isolated-CI build {key} must be {expected_value!r}; "
                    f"observed {observed!r}"
                )
    if ci_environment_matches and not unsigned_development:
        scope = "active isolated-CI build"
        expected.update(
            {
                "AD_HOC_CODE_SIGNING_ALLOWED": "YES",
                "CODE_SIGN_STYLE": "Manual",
                "CODE_SIGN_IDENTITY": "-",
                # Xcode removes an explicitly empty DEVELOPMENT_TEAM from the
                # script-phase environment and disables hardened runtime for an
                # ad-hoc identity.  The workflow/qualifier source guard above
                # separately proves those safer command-line inputs were
                # requested; this branch validates Xcode's effective result.
                "ENABLE_HARDENED_RUNTIME": "NO",
            }
        )
        expected.pop("DEVELOPMENT_TEAM")
        observed_team = environment.get("DEVELOPMENT_TEAM", "")
        if observed_team:
            errors.append(
                "active isolated-CI build DEVELOPMENT_TEAM must be empty or "
                f"omitted; observed {observed_team!r}"
            )
    for key, expected_value in expected.items():
        observed = environment.get(key)
        if observed != expected_value:
            errors.append(
                f"{scope} {key} must be {expected_value!r}; observed {observed!r}"
            )
    for key in PROFILELESS_BUILD_SETTINGS:
        observed = environment.get(key, "")
        if observed:
            errors.append(
                f"{scope} {key} must be empty or omitted; observed {observed!r}"
            )
    configuration = environment.get("CONFIGURATION")
    if configuration not in {"Debug", "Release"}:
        errors.append(
            "active build CONFIGURATION must be 'Debug' or 'Release'; "
            f"observed {configuration!r}"
        )
    else:
        expected_injection = EXPECTED_INJECT_BASE_ENTITLEMENTS_BY_CONFIGURATION[
            configuration
        ]
        injected_entitlements = environment.get("CODE_SIGN_INJECT_BASE_ENTITLEMENTS")
        if injected_entitlements != expected_injection:
            errors.append(
                f"active {configuration} build CODE_SIGN_INJECT_BASE_ENTITLEMENTS "
                f"must be {expected_injection!r}; "
                f"observed {injected_entitlements!r}"
            )
        authored_entitlements = environment.get("CODE_SIGN_ENTITLEMENTS", "")
        if authored_entitlements:
            errors.append(
                f"active {configuration} build CODE_SIGN_ENTITLEMENTS must be empty; "
                f"observed {authored_entitlements!r}"
            )
        live_test_condition = environment.get(
            "MACSCOPE_NATIVE_DECOMPILER_LIVE_TEST_CONDITION",
            "",
        )
        if configuration == "Release" and live_test_condition:
            errors.append(
                "active Release build "
                "MACSCOPE_NATIVE_DECOMPILER_LIVE_TEST_CONDITION must be empty; "
                f"observed {live_test_condition!r}"
            )
        live_symbol = "MACSCOPE_NATIVE_DECOMPILER_LIVE_XPC_TESTING"
        active_conditions = environment.get("SWIFT_ACTIVE_COMPILATION_CONDITIONS", "")
        if configuration == "Release" and live_symbol in active_conditions:
            errors.append(
                "active Release build SWIFT_ACTIVE_COMPILATION_CONDITIONS must not "
                f"contain {live_symbol}; observed {active_conditions!r}"
            )
        other_swift_flags = environment.get("OTHER_SWIFT_FLAGS", "")
        if configuration == "Release" and live_symbol in other_swift_flags:
            errors.append(
                "active Release build OTHER_SWIFT_FLAGS must not enable "
                f"{live_symbol}; observed {other_swift_flags!r}"
            )
    other_code_sign_flags = environment.get("OTHER_CODE_SIGN_FLAGS", "")
    if other_code_sign_flags:
        errors.append(
            "active build OTHER_CODE_SIGN_FLAGS must be empty; "
            f"observed {other_code_sign_flags!r}"
        )
    return errors


def run_xcodebuild_command(command: list[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        command,
        check=False,
        capture_output=True,
        text=True,
    )


def validate_xcode_project(
    xcodeproj: Path,
    command_runner: XcodeBuildCommandRunner = run_xcodebuild_command,
) -> list[str]:
    errors: list[str] = []

    def unique_object(pairs: list[tuple[str, object]]) -> dict[str, object]:
        value: dict[str, object] = {}
        for key, item in pairs:
            if key in value:
                raise ValueError(f"duplicate JSON settings key {key!r}")
            value[key] = item
        return value

    for configuration in ("Debug", "Release"):
        result = command_runner([
            "/usr/bin/xcodebuild", "-project", str(xcodeproj),
            "-alltargets", "-configuration", configuration, "-showBuildSettings", "-json",
        ])
        if result.returncode != 0:
            errors.append(f"xcodebuild could not resolve {configuration} target settings: {result.stderr.strip()}")
            continue
        try:
            entries = json.loads(result.stdout, object_pairs_hook=unique_object)
            if not isinstance(entries, list):
                raise ValueError("settings output must be an array")
            targets: dict[str, dict[str, str]] = {}
            for entry in entries:
                if not isinstance(entry, dict) or not isinstance(entry.get("target"), str):
                    raise ValueError("settings entry must identify a target")
                target = entry["target"]
                # Package graphs can repeat unrelated target names. Only signed
                # targets in the requested project are policy authority; a
                # same-named external target cannot satisfy completeness.
                if target not in EXPECTED_IDENTIFIERS_BY_TARGET:
                    continue
                settings = entry.get("buildSettings")
                if not isinstance(settings, dict) or any(not isinstance(value, str) for value in settings.values()):
                    raise ValueError(f"{target} settings must contain string values")
                project_path = settings.get("PROJECT_FILE_PATH")
                if not project_path or Path(project_path).resolve() != xcodeproj.resolve():
                    continue
                if target in targets:
                    raise ValueError(f"duplicate signed project target {target!r}")
                targets[target] = settings
            for target in EXPECTED_IDENTIFIERS_BY_TARGET:
                settings = targets.get(target)
                if settings is None:
                    errors.append(f"{configuration} is missing required signed target {target}")
                    continue
                if settings.get("CONFIGURATION") != configuration:
                    errors.append(f"{configuration} {target} settings have wrong CONFIGURATION {settings.get('CONFIGURATION')!r}")
                errors.extend(validate_effective_settings_values(settings, configuration, target))
        except (ValueError, TypeError) as error:
            errors.append(f"xcodebuild returned invalid {configuration} settings: {error}")
    return errors


def run_toolchain_command(
    command: list[str],
    environment: dict[str, str],
) -> subprocess.CompletedProcess[str]:
    command_environment = dict(os.environ)
    command_environment.update(environment)
    return subprocess.run(
        command,
        check=False,
        capture_output=True,
        text=True,
        env=command_environment,
    )


def validate_active_toolchain(
    environment: dict[str, str],
    command_runner: ToolchainCommandRunner = run_toolchain_command,
) -> list[str]:
    """Validate the active host and selected Xcode without pinning build numbers."""
    selected_environment = dict(environment)
    developer_directory = selected_environment.get(
        "DEVELOPER_DIR", "/Applications/Xcode.app/Contents/Developer"
    ).rstrip("/")
    selected_environment["DEVELOPER_DIR"] = developer_directory
    errors: list[str] = []

    def output(command: list[str], label: str) -> str | None:
        result = command_runner(command, selected_environment)
        if result.returncode != 0:
            diagnostic = command_output(result).strip() or "no diagnostic"
            errors.append(f"active toolchain {label} could not be determined: {diagnostic}")
            return None
        return command_output(result).strip()

    architecture = output(["/usr/bin/uname", "-m"], "host architecture")
    if architecture is not None and architecture != "arm64":
        errors.append(
            f"active toolchain host architecture must be arm64; observed {architecture!r}"
        )

    macos_version = output(
        ["/usr/bin/sw_vers", "-productVersion"], "host macOS version"
    )
    macos_match = re.match(r"^(\d+)(?:\.|$)", macos_version or "")
    if macos_version is not None and (
        macos_match is None or int(macos_match.group(1)) < 27
    ):
        errors.append(
            "active toolchain requires macOS 27.0 or newer; "
            f"observed {macos_version!r}"
        )

    xcode_version = output(
        ["/usr/bin/xcrun", "xcodebuild", "-version"], "Xcode version"
    )
    xcode_match = re.match(r"^Xcode\s+(\d+)(?:\.|\s|$)", xcode_version or "")
    if xcode_version is not None and (
        xcode_match is None or xcode_match.group(1) != "27"
    ):
        errors.append(
            f"active toolchain must use Xcode 27; observed {xcode_version!r}"
        )

    sdk_version = output(
        ["/usr/bin/xcrun", "--sdk", "macosx", "--show-sdk-version"],
        "macOS SDK version",
    )
    sdk_match = re.match(r"^(\d+)(?:\.|$)", sdk_version or "")
    if sdk_version is not None and (
        sdk_match is None or sdk_match.group(1) != "27"
    ):
        errors.append(
            f"active toolchain must use macOS SDK 27; observed {sdk_version!r}"
        )

    swift_path = output(["/usr/bin/xcrun", "--find", "swift"], "Swift path")
    if swift_path is not None and not swift_path.startswith(
        f"{developer_directory}/"
    ):
        errors.append(
            "active toolchain Swift must resolve inside DEVELOPER_DIR; "
            f"observed {swift_path!r}"
        )

    output(["/usr/bin/xcrun", "swift", "--version"], "Swift version")

    return errors


def run_artifact_command(command: list[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        command,
        check=False,
        capture_output=True,
        text=True,
    )


def command_output(result: subprocess.CompletedProcess[str]) -> str:
    return "\n".join(part for part in (result.stdout, result.stderr) if part)


def parse_codesign_details(output: str) -> dict[str, object]:
    details: dict[str, object] = {}
    authorities: list[str] = []
    for line in output.splitlines():
        if line.startswith("CodeDirectory "):
            details["CodeDirectory"] = line.removeprefix("CodeDirectory ").strip()
            continue
        if line.startswith("Authority="):
            authorities.append(line.removeprefix("Authority=").strip())
            continue
        if "=" not in line:
            continue
        key, value = line.split("=", 1)
        if key in {"Identifier", "TeamIdentifier"}:
            details[key] = value.strip()
    details["Authority"] = authorities
    return details


def unquoted_keyword_at(text: str, index: int, keyword: str) -> bool:
    if not text.startswith(keyword, index):
        return False
    before = text[index - 1] if index > 0 else ""
    after_index = index + len(keyword)
    after = text[after_index] if after_index < len(text) else ""
    identifier_character = lambda character: character.isalnum() or character == "_"
    return not identifier_character(before) and not identifier_character(after)


def split_requirement_conjunction(expression: str) -> list[str] | None:
    """Split only unquoted `and`; reject every unquoted disjunction."""
    clauses: list[str] = []
    clause_start = 0
    in_quote = False
    escaped = False
    index = 0
    while index < len(expression):
        character = expression[index]
        if in_quote:
            if escaped:
                escaped = False
            elif character == "\\":
                escaped = True
            elif character == '"':
                in_quote = False
            index += 1
            continue
        if character == '"':
            in_quote = True
            index += 1
            continue
        if unquoted_keyword_at(expression, index, "or"):
            return None
        if unquoted_keyword_at(expression, index, "and"):
            clause = expression[clause_start:index].strip()
            if not clause:
                return None
            clauses.append(clause)
            index += len("and")
            clause_start = index
            continue
        index += 1
    if in_quote or escaped:
        return None
    final_clause = expression[clause_start:].strip()
    if not final_clause:
        return None
    clauses.append(final_clause)
    return clauses


def parse_exact_designated_requirement(
    output: str,
    expected_identifier: str,
) -> tuple[str | None, str | None]:
    """Accept exactly the four certificate-backed clauses, in any order."""
    markers = list(
        re.finditer(r"(?m)^[ \t]*designated[ \t]*=>", output)
    )
    if len(markers) != 1:
        return None, "expected exactly one designated requirement"
    expression = output[markers[0].end() :].strip()
    clauses = split_requirement_conjunction(expression)
    if clauses is None:
        return None, "requirement must be a conjunction without disjunctions"

    whitespace = r"\s+"
    optional_whitespace = r"\s*"
    identifier_pattern = re.compile(
        rf"identifier{whitespace}\"{re.escape(expected_identifier)}\""
    )
    anchor_pattern = re.compile(
        rf"anchor{whitespace}apple{whitespace}generic"
    )
    leaf_pattern = re.compile(
        rf"certificate{whitespace}leaf{optional_whitespace}"
        rf"\[{optional_whitespace}subject{optional_whitespace}\."
        rf"{optional_whitespace}CN{optional_whitespace}\]"
        rf"{optional_whitespace}={optional_whitespace}"
        r'"(?P<subject>Apple Development:[^"\r\n]+)"'
    )
    intermediate_pattern = re.compile(
        rf"certificate{whitespace}1{optional_whitespace}"
        rf"\[{optional_whitespace}field{optional_whitespace}\."
        rf"{optional_whitespace}1{optional_whitespace}\."
        rf"{optional_whitespace}2{optional_whitespace}\."
        rf"{optional_whitespace}840{optional_whitespace}\."
        rf"{optional_whitespace}113635{optional_whitespace}\."
        rf"{optional_whitespace}100{optional_whitespace}\."
        rf"{optional_whitespace}6{optional_whitespace}\."
        rf"{optional_whitespace}2{optional_whitespace}\."
        rf"{optional_whitespace}1{optional_whitespace}\]"
        rf"{whitespace}(?:exists|/\*{optional_whitespace}exists"
        rf"{optional_whitespace}\*/)"
    )
    patterns = {
        "identifier": identifier_pattern,
        "anchor": anchor_pattern,
        "leaf": leaf_pattern,
        "intermediate": intermediate_pattern,
    }
    observed: dict[str, re.Match[str]] = {}
    for clause in clauses:
        matches = [
            (kind, match)
            for kind, pattern in patterns.items()
            if (match := pattern.fullmatch(clause)) is not None
        ]
        if len(matches) != 1:
            return None, f"unexpected designated-requirement clause {clause!r}"
        kind, match = matches[0]
        if kind in observed:
            return None, f"duplicate designated-requirement clause {kind!r}"
        observed[kind] = match
    if set(observed) != set(patterns):
        missing = sorted(set(patterns) - set(observed))
        return None, f"missing designated-requirement clauses {missing!r}"
    return observed["leaf"].group("subject"), None


def parse_entitlements(output: str) -> tuple[dict[str, object] | None, str | None]:
    """Extract the XML plist from codesign output; no plist means no entitlements."""
    xml_start = output.find("<?xml")
    if xml_start < 0:
        return {}, None
    xml_end_marker = "</plist>"
    xml_end = output.find(xml_end_marker, xml_start)
    if xml_end < 0:
        return None, "codesign returned a truncated entitlement plist"
    payload = output[xml_start : xml_end + len(xml_end_marker)].encode("utf-8")
    try:
        entitlements = plistlib.loads(payload)
    except (plistlib.InvalidFileException, ValueError) as error:
        return None, f"codesign returned invalid entitlement data: {error}"
    if not isinstance(entitlements, dict):
        return None, "codesign entitlement payload must be a dictionary"
    return entitlements, None


def stable_artifact_fields(value: os.stat_result) -> tuple[int, ...]:
    return (
        value.st_dev,
        value.st_ino,
        value.st_mode,
        value.st_nlink,
        value.st_size,
        value.st_mtime_ns,
        value.st_ctime_ns,
    )


def safe_directory_entries(
    directory: Path,
    label: str,
) -> tuple[list[str] | None, list[str]]:
    try:
        metadata = directory.lstat()
    except OSError as error:
        return None, [f"{label} is missing or inaccessible: {error}"]
    if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISDIR(metadata.st_mode):
        return None, [f"{label} must be a non-symlink directory: {directory}"]
    try:
        with os.scandir(directory) as iterator:
            entries = list(iterator)
    except OSError as error:
        return None, [f"{label} could not be inventoried: {error}"]
    linked = sorted(
        (entry.name for entry in entries if entry.is_symlink()),
        key=os.fsencode,
    )
    errors = (
        [f"{label} contains symlink substitutions: {linked!r}"]
        if linked
        else []
    )
    return sorted((entry.name for entry in entries), key=os.fsencode), errors


def read_stable_regular_bytes(
    path: Path,
    label: str,
    maximum_bytes: int,
    *,
    expected_mode: int | None = None,
) -> tuple[bytes | None, list[str]]:
    try:
        before = path.lstat()
    except OSError as error:
        return None, [f"{label} is missing or inaccessible: {error}"]
    if (
        stat.S_ISLNK(before.st_mode)
        or not stat.S_ISREG(before.st_mode)
        or before.st_nlink != 1
    ):
        return None, [f"{label} must be an ordinary singly linked file: {path}"]
    if expected_mode is not None and stat.S_IMODE(before.st_mode) != expected_mode:
        return None, [
            f"{label} mode must be {expected_mode:o}; observed "
            f"{stat.S_IMODE(before.st_mode):o}"
        ]
    descriptor = -1
    try:
        descriptor = os.open(
            path,
            os.O_RDONLY
            | getattr(os, "O_NOFOLLOW", 0)
            | getattr(os, "O_CLOEXEC", 0),
        )
        opened = os.fstat(descriptor)
        chunks: list[bytes] = []
        remaining = maximum_bytes + 1
        while remaining:
            chunk = os.read(descriptor, min(1024 * 1024, remaining))
            if not chunk:
                break
            chunks.append(chunk)
            remaining -= len(chunk)
        payload = b"".join(chunks)
        after_open = os.fstat(descriptor)
    except OSError as error:
        return None, [f"{label} could not be read safely: {error}"]
    finally:
        if descriptor >= 0:
            os.close(descriptor)
    try:
        after_path = path.lstat()
    except OSError as error:
        return None, [f"{label} changed while read: {error}"]
    if (
        len(payload) > maximum_bytes
        or stable_artifact_fields(before) != stable_artifact_fields(opened)
        or stable_artifact_fields(before) != stable_artifact_fields(after_open)
        or stable_artifact_fields(before) != stable_artifact_fields(after_path)
    ):
        return None, [f"{label} exceeds its size bound or changed while read"]
    return payload, []


def sha256_stable_artifact_file(path: Path, label: str) -> str:
    try:
        before = path.lstat()
    except OSError as error:
        raise ValueError(f"{label} is missing or inaccessible: {error}") from error
    if (
        stat.S_ISLNK(before.st_mode)
        or not stat.S_ISREG(before.st_mode)
        or before.st_nlink != 1
    ):
        raise ValueError(f"{label} must be an ordinary singly linked file")
    descriptor = -1
    digest = hashlib.sha256()
    try:
        descriptor = os.open(
            path,
            os.O_RDONLY
            | getattr(os, "O_NOFOLLOW", 0)
            | getattr(os, "O_CLOEXEC", 0),
        )
        opened = os.fstat(descriptor)
        while chunk := os.read(descriptor, 1024 * 1024):
            digest.update(chunk)
        after_open = os.fstat(descriptor)
    except OSError as error:
        raise ValueError(f"{label} could not be hashed safely: {error}") from error
    finally:
        if descriptor >= 0:
            os.close(descriptor)
    try:
        after_path = path.lstat()
    except OSError as error:
        raise ValueError(f"{label} changed while hashed: {error}") from error
    if (
        stable_artifact_fields(before) != stable_artifact_fields(opened)
        or stable_artifact_fields(before) != stable_artifact_fields(after_open)
        or stable_artifact_fields(before) != stable_artifact_fields(after_path)
    ):
        raise ValueError(f"{label} changed while hashed")
    return digest.hexdigest()


class DuplicateReleaseProvenanceKey(ValueError):
    pass


def release_provenance_object(
    pairs: list[tuple[str, object]],
) -> dict[str, object]:
    result: dict[str, object] = {}
    for key, value in pairs:
        if key in result:
            raise DuplicateReleaseProvenanceKey(key)
        result[key] = value
    return result


def repository_head_identity(
    repository_root: Path = REPOSITORY_ROOT,
) -> tuple[tuple[str, str] | None, list[str]]:
    values: list[str] = []
    for revision in ("HEAD", "HEAD^{tree}"):
        result = subprocess.run(
            ["/usr/bin/git", "-C", str(repository_root), "rev-parse", "--verify", revision],
            check=False,
            capture_output=True,
            text=True,
        )
        value = result.stdout.strip()
        if result.returncode != 0 or LOWERCASE_GIT_OID.fullmatch(value) is None:
            diagnostic = command_output(result).strip() or "no diagnostic"
            return None, [
                "Release candidate source identity could not be resolved from the "
                f"repository for {revision}: {diagnostic}"
            ]
        values.append(value)
    return (values[0], values[1]), []


def validate_release_provenance(
    app_bundle: Path,
    *,
    expected_source_commit: str | None = None,
    expected_source_tree: str | None = None,
) -> tuple[dict[str, object] | None, list[str]]:
    provenance_path = app_bundle / RELEASE_PROVENANCE_RELATIVE_PATH
    payload_bytes, errors = read_stable_regular_bytes(
        provenance_path,
        "sealed Release provenance",
        RELEASE_PROVENANCE_MAX_BYTES,
        expected_mode=0o644,
    )
    if payload_bytes is None:
        return None, errors
    try:
        payload = json.loads(
            payload_bytes,
            object_pairs_hook=release_provenance_object,
            parse_float=lambda value: (_ for _ in ()).throw(ValueError(value)),
            parse_constant=lambda value: (_ for _ in ()).throw(ValueError(value)),
        )
    except DuplicateReleaseProvenanceKey as error:
        return None, [
            f"sealed Release provenance contains duplicate key {error.args[0]!r}"
        ]
    except (UnicodeDecodeError, json.JSONDecodeError, ValueError) as error:
        return None, [f"sealed Release provenance is malformed JSON: {error}"]
    if not isinstance(payload, dict):
        return None, ["sealed Release provenance must be a JSON object"]
    try:
        expected_encoding = (
            json.dumps(
                payload,
                ensure_ascii=True,
                allow_nan=False,
                sort_keys=True,
                separators=(",", ":"),
            )
            + "\n"
        ).encode("utf-8")
    except (TypeError, ValueError) as error:
        return None, [f"sealed Release provenance is not canonical data: {error}"]
    if payload_bytes != expected_encoding:
        errors.append("sealed Release provenance must use exact canonical JSON encoding")

    for key, expected in EXPECTED_RELEASE_PROVENANCE_SCALARS.items():
        observed = payload.get(key)
        if type(observed) is not type(expected) or observed != expected:
            errors.append(
                f"sealed Release provenance {key} must be {expected!r}; "
                f"observed {observed!r}"
            )
    for key in RELEASE_PROVENANCE_SHA256_FIELDS:
        value = payload.get(key)
        if not isinstance(value, str) or LOWERCASE_SHA256.fullmatch(value) is None:
            errors.append(
                f"sealed Release provenance {key} must be one lowercase SHA-256"
            )

    source_commit = payload.get("git_head_commit")
    source_tree = payload.get("git_head_tree")
    if not isinstance(source_commit, str) or LOWERCASE_GIT_OID.fullmatch(source_commit) is None:
        errors.append(
            "sealed Release provenance git_head_commit must be one lowercase Git OID"
        )
    if not isinstance(source_tree, str) or LOWERCASE_GIT_OID.fullmatch(source_tree) is None:
        errors.append(
            "sealed Release provenance git_head_tree must be one lowercase Git OID"
        )
    if expected_source_commit is not None and source_commit != expected_source_commit:
        errors.append(
            "sealed Release provenance source commit must equal the admitted candidate "
            f"commit {expected_source_commit}; observed {source_commit!r}"
        )
    if expected_source_tree is not None and source_tree != expected_source_tree:
        errors.append(
            "sealed Release provenance source tree must equal the admitted candidate "
            f"tree {expected_source_tree}; observed {source_tree!r}"
        )

    bound_files = (
        (
            app_bundle
            / "Contents/XPCServices/AnalysisWorkerXPCService.xpc/Contents/MacOS/"
            "AnalysisWorkerXPCService",
            "machokit_analysis_worker_executable_sha256",
            "AnalysisWorkerXPCService executable",
        ),
        (
            app_bundle
            / "Contents/XPCServices/NativeDecompilerXPCService.xpc/Contents/MacOS/"
            "NativeDecompilerXPCService",
            "native_decompiler_embedded_service_executable_sha256",
            "NativeDecompilerXPCService executable",
        ),
        (
            app_bundle
            / "Contents/XPCServices/NativeDecompilerXPCService.xpc/Contents/"
            "_CodeSignature/CodeResources",
            "native_decompiler_embedded_service_code_resources_sha256",
            "NativeDecompilerXPCService CodeResources",
        ),
    )
    if expected_source_commit is not None and expected_source_tree is not None:
        for path, field, label in bound_files:
            try:
                observed = sha256_stable_artifact_file(path, label)
            except ValueError as error:
                errors.append(str(error))
                continue
            if payload.get(field) != observed:
                errors.append(
                    f"sealed Release provenance {field} does not bind the exact {label}"
                )
    return payload, errors


def read_bundle_metadata(
    bundle: Path,
    label: str,
    expected_identifier: str,
) -> tuple[Path | None, list[str]]:
    errors: list[str] = []
    try:
        bundle_metadata = bundle.lstat()
    except OSError as error:
        return None, [f"{label} is missing at {bundle}: {error}"]
    if stat.S_ISLNK(bundle_metadata.st_mode) or not stat.S_ISDIR(bundle_metadata.st_mode):
        return None, [f"{label} must be a non-symlink bundle directory at {bundle}"]

    for relative, directory_label in (
        (Path("Contents"), "Contents"),
        (Path("Contents/MacOS"), "Contents/MacOS"),
    ):
        directory = bundle / relative
        try:
            metadata = directory.lstat()
        except OSError as error:
            return None, [f"{label} {directory_label} is missing: {error}"]
        if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISDIR(metadata.st_mode):
            return None, [
                f"{label} {directory_label} must be a non-symlink directory"
            ]

    info_plist = bundle / "Contents" / "Info.plist"
    info_bytes, info_errors = read_stable_regular_bytes(
        info_plist,
        f"{label} Info.plist",
        1024 * 1024,
    )
    errors.extend(info_errors)
    if info_bytes is None:
        return None, errors
    try:
        metadata = plistlib.loads(info_bytes)
    except plistlib.InvalidFileException as error:
        return None, [f"{label} Info.plist could not be read: {error}"]
    if not isinstance(metadata, dict):
        return None, [f"{label} Info.plist must contain a dictionary"]

    observed_identifier = metadata.get("CFBundleIdentifier")
    if observed_identifier != expected_identifier:
        errors.append(
            f"{label} CFBundleIdentifier must be {expected_identifier!r}; "
            f"observed {observed_identifier!r}"
        )
    executable_name = metadata.get("CFBundleExecutable")
    if not isinstance(executable_name, str) or not executable_name:
        errors.append(f"{label} CFBundleExecutable must name its executable")
        return None, errors
    expected_executable_name = EXPECTED_EXECUTABLE_BY_IDENTIFIER.get(
        expected_identifier
    )
    if executable_name != expected_executable_name:
        errors.append(
            f"{label} CFBundleExecutable must be {expected_executable_name!r}; "
            f"observed {executable_name!r}"
        )
        return None, errors
    executable = bundle / "Contents" / "MacOS" / executable_name
    try:
        executable_metadata = executable.lstat()
    except OSError as error:
        errors.append(f"{label} executable is missing at {executable}: {error}")
        return None, errors
    if (
        stat.S_ISLNK(executable_metadata.st_mode)
        or not stat.S_ISREG(executable_metadata.st_mode)
        or executable_metadata.st_nlink != 1
    ):
        errors.append(
            f"{label} executable must be a non-symlink singly linked regular file "
            f"at {executable}"
        )
        return None, errors
    return executable, errors


def validate_signed_bundle(
    bundle: Path,
    executable: Path,
    label: str,
    expected_identifier: str,
    configuration: str,
    command_runner: ArtifactCommandRunner,
    *,
    expected_entitlements: dict[str, object] | None = None,
    expected_entitlements_description: str = "",
) -> tuple[list[str], str | None]:
    errors: list[str] = []
    leaf_authority: str | None = None
    code_resources_path: Path | None = None
    code_resources_metadata: os.stat_result | None = None
    try:
        executable_metadata = executable.lstat()
    except OSError as error:
        return [f"{label} executable is missing or inaccessible: {error}"], None
    if (
        stat.S_ISLNK(executable_metadata.st_mode)
        or not stat.S_ISREG(executable_metadata.st_mode)
        or executable_metadata.st_nlink != 1
    ):
        return [
            f"{label} executable must be a non-symlink singly linked regular file"
        ], None
    if bundle != executable:
        signature_directory = bundle / "Contents" / "_CodeSignature"
        code_resources_path = signature_directory / "CodeResources"
        try:
            signature_metadata = signature_directory.lstat()
            code_resources_metadata = code_resources_path.lstat()
        except OSError as error:
            errors.append(f"{label} CodeResources is missing or inaccessible: {error}")
        else:
            if (
                stat.S_ISLNK(signature_metadata.st_mode)
                or not stat.S_ISDIR(signature_metadata.st_mode)
                or stat.S_ISLNK(code_resources_metadata.st_mode)
                or not stat.S_ISREG(code_resources_metadata.st_mode)
                or code_resources_metadata.st_nlink != 1
            ):
                errors.append(
                    f"{label} CodeResources must be a non-symlink singly linked "
                    "regular file beneath an ordinary _CodeSignature directory"
                )
                code_resources_metadata = None

    verification = command_runner(
        [
            "/usr/bin/codesign",
            "--verify",
            "--deep",
            "--strict",
            "--verbose=2",
            str(bundle),
        ]
    )
    if verification.returncode != 0:
        diagnostic = command_output(verification).strip() or "no diagnostic"
        errors.append(f"{label} failed strict/deep codesign verification: {diagnostic}")

    detail_result = command_runner(["/usr/bin/codesign", "-dvvv", str(bundle)])
    if detail_result.returncode != 0:
        diagnostic = command_output(detail_result).strip() or "no diagnostic"
        errors.append(f"{label} signing details could not be read: {diagnostic}")
    else:
        details = parse_codesign_details(command_output(detail_result))
        signed_identifier = details.get("Identifier")
        if signed_identifier != expected_identifier:
            errors.append(
                f"{label} signed Identifier must be {expected_identifier!r}; "
                f"observed {signed_identifier!r}"
            )
        authorities = details.get("Authority")
        leaf_authority = (
            authorities[0]
            if isinstance(authorities, list) and authorities
            else None
        )
        if leaf_authority != EXPECTED_SIGNER_SUBJECT:
            errors.append(
                f"{label} leaf Authority must be {EXPECTED_SIGNER_SUBJECT!r}; "
                f"observed {leaf_authority!r}"
            )
        team_identifier = details.get("TeamIdentifier")
        if team_identifier != EXPECTED_TEAM_IDENTIFIER:
            errors.append(
                f"{label} TeamIdentifier must be {EXPECTED_TEAM_IDENTIFIER!r}; "
                f"observed {team_identifier!r}"
            )
        code_directory = details.get("CodeDirectory")
        if not isinstance(code_directory, str) or not re.search(
            r"\bflags=.*(?:\(|,)runtime(?:\)|,)", code_directory
        ):
            errors.append(f"{label} must enable the hardened runtime")

    requirement_result = command_runner(
        ["/usr/bin/codesign", "-d", "-r-", str(bundle)]
    )
    requirement_output = next(
        (
            channel
            for channel in (requirement_result.stdout, requirement_result.stderr)
            if re.search(r"(?m)^[ \t]*designated[ \t]*=>", channel)
        ),
        command_output(requirement_result),
    )
    requirement_subject, requirement_error = parse_exact_designated_requirement(
        requirement_output,
        expected_identifier,
    )
    if requirement_result.returncode != 0 or requirement_error is not None:
        errors.append(
            f"{label} must have the exact conjunctive designated requirement "
            "with certificate-backed identifier, anchor apple generic, Apple "
            "Development leaf CN, and Apple "
            "intermediate constraint for "
            f"{expected_identifier}; observed {requirement_error or 'codesign failure'}"
        )
    elif requirement_subject != EXPECTED_SIGNER_SUBJECT:
        errors.append(
            f"{label} designated-requirement subject must be "
            f"{EXPECTED_SIGNER_SUBJECT!r}; observed {requirement_subject!r}"
        )
    if (
        leaf_authority is not None
        and requirement_subject is not None
        and leaf_authority != requirement_subject
    ):
        errors.append(
            f"{label} designated-requirement subject {requirement_subject!r} "
            f"does not match signing Authority {leaf_authority!r}"
        )

    architecture_result = command_runner(
        ["/usr/bin/lipo", "-archs", str(executable)]
    )
    observed_architectures = architecture_result.stdout.strip()
    if architecture_result.returncode != 0 or observed_architectures != "arm64":
        errors.append(
            f"{label} executable must be arm64-only; "
            f"observed {observed_architectures!r}"
        )

    deployment_result = command_runner(
        ["/usr/bin/xcrun", "vtool", "-show-build", str(executable)]
    )
    deployment_output = command_output(deployment_result)
    minimum_versions = re.findall(
        r"^\s*minos\s+([0-9]+(?:\.[0-9]+){1,2})\s*$",
        deployment_output,
        flags=re.MULTILINE,
    )
    if deployment_result.returncode != 0 or minimum_versions != [EXPECTED_DEPLOYMENT_TARGET]:
        observed = minimum_versions if minimum_versions else deployment_output.strip()
        errors.append(
            f"{label} executable minimum macOS version must be "
            f"{EXPECTED_DEPLOYMENT_TARGET}; observed {observed!r}"
        )

    entitlement_result = command_runner(
        ["/usr/bin/codesign", "-d", "--entitlements", ":-", str(bundle)]
    )
    if entitlement_result.returncode != 0:
        diagnostic = command_output(entitlement_result).strip() or "no diagnostic"
        errors.append(f"{label} entitlements could not be read: {diagnostic}")
    else:
        entitlements, entitlement_error = parse_entitlements(
            command_output(entitlement_result)
        )
        if entitlement_error is not None:
            errors.append(f"{label} {entitlement_error}")
        elif expected_entitlements is not None and entitlements != expected_entitlements:
            errors.append(
                f"{label} entitlements must exactly match "
                f"{expected_entitlements_description}"
            )
        elif (
            expected_entitlements is None
            and configuration in {"Debug", "Release"}
            and entitlements not in (
                {},
                {"com.apple.security.get-task-allow": True},
            )
        ):
            errors.append(
                f"{label} {configuration} entitlements may contain only enabled "
                "com.apple.security.get-task-allow"
            )

    stable_signer = (
        leaf_authority
        if leaf_authority is not None and leaf_authority == requirement_subject
        else None
    )
    if code_resources_path is not None and code_resources_metadata is not None:
        try:
            observed_code_resources = code_resources_path.lstat()
        except OSError as error:
            errors.append(f"{label} CodeResources changed during validation: {error}")
        else:
            if stable_artifact_fields(observed_code_resources) != stable_artifact_fields(
                code_resources_metadata
            ):
                errors.append(f"{label} CodeResources changed during validation")
    try:
        observed_executable_metadata = executable.lstat()
    except OSError as error:
        errors.append(f"{label} executable changed during validation: {error}")
    else:
        if stable_artifact_fields(observed_executable_metadata) != stable_artifact_fields(
            executable_metadata
        ):
            errors.append(f"{label} executable changed during validation")
    return errors, stable_signer


def validate_app_bundle(
    app_bundle: Path,
    configuration: str,
    command_runner: ArtifactCommandRunner = run_artifact_command,
    *,
    xcode_test_host: bool = False,
    expected_source_commit: str | None = None,
    expected_source_tree: str | None = None,
) -> list[str]:
    """Validate the local app and its mandatory embedded workers after a build."""
    if configuration not in {"Debug", "Release"}:
        return [f"artifact configuration must be Debug or Release; observed {configuration!r}"]
    if xcode_test_host and configuration != "Debug":
        return ["the Xcode test-host entitlement profile is permitted only for Debug artifacts"]

    errors: list[str] = []
    signer_subjects: list[tuple[str, str]] = []
    if app_bundle.name != "MacScope.app":
        errors.append(
            f"Release candidate bundle must be named MacScope.app; observed {app_bundle.name!r}"
        )
    app_macos_entries, inventory_errors = safe_directory_entries(
        app_bundle / "Contents" / "MacOS",
        "MacScope.app Contents/MacOS inventory",
    )
    errors.extend(inventory_errors)
    if app_macos_entries is not None and set(app_macos_entries) != (
        EXPECTED_RELEASE_MACOS_EXECUTABLES
    ):
        errors.append(
            "MacScope.app Contents/MacOS must contain exactly MacScope and "
            f"ShellBrokerLaunchAgent and SourceExecutionRunner; observed {app_macos_entries!r}"
        )

    frameworks_root = app_bundle / "Contents" / "Frameworks"
    framework_entries, inventory_errors = safe_directory_entries(
        frameworks_root,
        "MacScope.app Contents/Frameworks inventory",
    )
    errors.extend(inventory_errors)
    if framework_entries is not None and framework_entries != [
        EXPECTED_GHOSTTY_VT_DYLIB
    ]:
        errors.append(
            "MacScope.app Contents/Frameworks must contain exactly "
            f"{EXPECTED_GHOSTTY_VT_DYLIB!r}; observed {framework_entries!r}"
        )

    xpc_root = app_bundle / "Contents" / "XPCServices"
    xpc_entries, inventory_errors = safe_directory_entries(
        xpc_root,
        "MacScope.app XPCServices inventory",
    )
    errors.extend(inventory_errors)
    expected_xpc_names = set(EXPECTED_RELEASE_XPC_BUNDLES)
    if xpc_entries is not None and set(xpc_entries) != expected_xpc_names:
        errors.append(
            "MacScope.app must embed exactly the four approved XPC services; "
            f"observed {xpc_entries!r}"
        )
    for bundle_name, (executable_name, _identifier) in (
        EXPECTED_RELEASE_XPC_BUNDLES.items()
    ):
        executable_entries, executable_inventory_errors = safe_directory_entries(
            xpc_root / bundle_name / "Contents" / "MacOS",
            f"{bundle_name} executable inventory",
        )
        errors.extend(executable_inventory_errors)
        if executable_entries is not None and executable_entries != [executable_name]:
            errors.append(
                f"{bundle_name} Contents/MacOS must contain exactly "
                f"{executable_name!r}; observed {executable_entries!r}"
            )

    plugins = app_bundle / "Contents" / "PlugIns"
    if xcode_test_host:
        plugin_entries, plugin_errors = safe_directory_entries(
            plugins,
            "MacScope.app Debug test PlugIns inventory",
        )
        errors.extend(plugin_errors)
        if plugin_entries is not None and plugin_entries != ["CoreTests.xctest"]:
            errors.append(
                "Debug Xcode test-host candidate must contain exactly CoreTests.xctest "
                f"in Contents/PlugIns; observed {plugin_entries!r}"
            )
    else:
        try:
            plugin_metadata = plugins.lstat()
        except FileNotFoundError:
            pass
        except OSError as error:
            errors.append(f"MacScope.app Contents/PlugIns could not be inspected: {error}")
        else:
            kind = "symlink" if stat.S_ISLNK(plugin_metadata.st_mode) else "directory"
            errors.append(
                "ordinary MacScope.app candidate must not contain test or plugin "
                f"products in Contents/PlugIns; observed {kind}"
            )

    app_product_entitlements = (
        EXPECTED_XCODE_TEST_HOST_ENTITLEMENTS if xcode_test_host else None
    )
    app_product_entitlements_description = (
        "the governed Debug Xcode test-host injection profile"
        if xcode_test_host
        else ""
    )
    products = [
        (app_bundle, "MacScope.app", EXPECTED_APP_IDENTIFIER),
        (
            app_bundle
            / "Contents"
            / "XPCServices"
            / "AnalysisWorkerXPCService.xpc",
            "AnalysisWorkerXPCService.xpc",
            EXPECTED_WORKER_IDENTIFIER,
        ),
        (
            app_bundle
            / "Contents"
            / "XPCServices"
            / "AIAgentWorkerXPCService.xpc",
            "AIAgentWorkerXPCService.xpc",
            EXPECTED_AI_WORKER_IDENTIFIER,
        ),
        (
            app_bundle
            / "Contents"
            / "XPCServices"
            / "NativeDecompilerXPCService.xpc",
            "NativeDecompilerXPCService.xpc",
            EXPECTED_NATIVE_DECOMPILER_IDENTIFIER,
        ),
        (
            app_bundle
            / "Contents"
            / "XPCServices"
            / "ShellBrokerXPCService.xpc",
            "ShellBrokerXPCService.xpc",
            EXPECTED_SHELL_BROKER_IDENTIFIER,
        ),
    ]
    for bundle, label, expected_identifier in products:
        executable, metadata_errors = read_bundle_metadata(
            bundle, label, expected_identifier
        )
        errors.extend(metadata_errors)
        if executable is None:
            continue
        bundle_errors, signer_subject = validate_signed_bundle(
            bundle,
            executable,
            label,
            expected_identifier,
            configuration,
            command_runner,
            expected_entitlements=app_product_entitlements,
            expected_entitlements_description=app_product_entitlements_description,
        )
        errors.extend(bundle_errors)
        if signer_subject is not None:
            signer_subjects.append((label, signer_subject))

    ghostty_vt = frameworks_root / EXPECTED_GHOSTTY_VT_DYLIB
    try:
        ghostty_vt_metadata = ghostty_vt.lstat()
    except OSError as error:
        errors.append(f"{EXPECTED_GHOSTTY_VT_DYLIB} is missing: {error}")
    else:
        if (
            stat.S_ISLNK(ghostty_vt_metadata.st_mode)
            or not stat.S_ISREG(ghostty_vt_metadata.st_mode)
            or ghostty_vt_metadata.st_nlink != 1
        ):
            errors.append(
                f"{EXPECTED_GHOSTTY_VT_DYLIB} must be a non-symlink singly "
                "linked regular file"
            )
        else:
            ghostty_vt_errors, ghostty_vt_signer = validate_signed_bundle(
                ghostty_vt,
                ghostty_vt,
                EXPECTED_GHOSTTY_VT_DYLIB,
                EXPECTED_GHOSTTY_VT_IDENTIFIER,
                configuration,
                command_runner,
                expected_entitlements={},
                expected_entitlements_description=(
                    "the exact observed empty dylib entitlement profile"
                ),
            )
            errors.extend(ghostty_vt_errors)
            if ghostty_vt_signer is not None:
                signer_subjects.append(
                    (EXPECTED_GHOSTTY_VT_DYLIB, ghostty_vt_signer)
                )

    if xcode_test_host:
        core_tests = app_bundle / "Contents" / "PlugIns" / "CoreTests.xctest"
        if core_tests.is_symlink():
            errors.append(f"CoreTests.xctest must not be a symlink: {core_tests}")
        else:
            core_executable, core_metadata_errors = read_bundle_metadata(
                core_tests,
                "CoreTests.xctest",
                EXPECTED_CORETESTS_IDENTIFIER,
            )
            errors.extend(core_metadata_errors)
            if core_executable is not None:
                core_errors, core_signer = validate_signed_bundle(
                    core_tests,
                    core_executable,
                    "CoreTests.xctest",
                    EXPECTED_CORETESTS_IDENTIFIER,
                    configuration,
                    command_runner,
                    expected_entitlements={},
                    expected_entitlements_description=(
                        "the exact observed empty entitlement profile"
                    ),
                )
                errors.extend(core_errors)
                if core_signer is not None:
                    signer_subjects.append(("CoreTests.xctest", core_signer))

    launch_agent = app_bundle / "Contents" / "MacOS" / "ShellBrokerLaunchAgent"
    try:
        launch_agent_metadata = launch_agent.lstat()
    except OSError:
        errors.append(
            "ShellBrokerLaunchAgent is missing or is not a non-symlink regular "
            f"file at {launch_agent}"
        )
    else:
        if (
            stat.S_ISLNK(launch_agent_metadata.st_mode)
            or not stat.S_ISREG(launch_agent_metadata.st_mode)
            or launch_agent_metadata.st_nlink != 1
        ):
            errors.append(
                "ShellBrokerLaunchAgent is missing or is not a non-symlink "
                f"singly linked regular file at {launch_agent}"
            )
        else:
            if xcode_test_host:
                launch_entitlements = EXPECTED_SHELL_BROKER_LAUNCH_AGENT_ENTITLEMENTS
                launch_entitlements_description = (
                    "the exact observed Debug test-host LaunchAgent profile, including "
                    "its application identifier"
                )
            elif configuration == "Release":
                # The local-development Release injects the SDK application identity
                # and get-task-allow, but never the broader Xcode test-host exceptions.
                launch_entitlements = EXPECTED_RELEASE_SHELL_BROKER_LAUNCH_AGENT_ENTITLEMENTS
                launch_entitlements_description = (
                    "the exact ordinary Release development LaunchAgent profile"
                )
            else:
                launch_entitlements = {}
                launch_entitlements_description = "the exact observed ordinary empty LaunchAgent profile"
            launch_errors, launch_signer = validate_signed_bundle(
                launch_agent,
                launch_agent,
                "ShellBrokerLaunchAgent",
                EXPECTED_SHELL_BROKER_LAUNCH_AGENT_IDENTIFIER,
                configuration,
                command_runner,
                expected_entitlements=launch_entitlements,
                expected_entitlements_description=launch_entitlements_description,
            )
            errors.extend(launch_errors)
            if launch_signer is not None:
                signer_subjects.append(("ShellBrokerLaunchAgent", launch_signer))

    launch_agent = app_bundle / "Contents" / "MacOS" / "SourceExecutionRunner"
    try:
        launch_agent_metadata = launch_agent.lstat()
    except OSError:
        errors.append(
            "SourceExecutionRunner is missing or is not a non-symlink regular "
            f"file at {launch_agent}"
        )
    else:
        if (
            stat.S_ISLNK(launch_agent_metadata.st_mode)
            or not stat.S_ISREG(launch_agent_metadata.st_mode)
            or launch_agent_metadata.st_nlink != 1
        ):
            errors.append(
                "SourceExecutionRunner is missing or is not a non-symlink "
                f"singly linked regular file at {launch_agent}"
            )
        else:
            if xcode_test_host:
                launch_entitlements = EXPECTED_SOURCE_EXECUTION_RUNNER_ENTITLEMENTS
                launch_entitlements_description = (
                    "the exact observed Debug test-host source-runner profile, including "
                    "its application identifier"
                )
            elif configuration == "Release":
                # The local-development Release injects the SDK application identity
                # and get-task-allow, but never the broader Xcode test-host exceptions.
                launch_entitlements = EXPECTED_RELEASE_SOURCE_EXECUTION_RUNNER_ENTITLEMENTS
                launch_entitlements_description = (
                    "the exact ordinary Release development source-runner profile"
                )
            else:
                launch_entitlements = {}
                launch_entitlements_description = "the exact observed ordinary empty source-runner profile"
            launch_errors, launch_signer = validate_signed_bundle(
                launch_agent,
                launch_agent,
                "SourceExecutionRunner",
                EXPECTED_SOURCE_EXECUTION_RUNNER_IDENTIFIER,
                configuration,
                command_runner,
                expected_entitlements=launch_entitlements,
                expected_entitlements_description=launch_entitlements_description,
            )
            errors.extend(launch_errors)
            if launch_signer is not None:
                signer_subjects.append(("SourceExecutionRunner", launch_signer))

    distinct_signers = {subject for _, subject in signer_subjects}
    if len(distinct_signers) > 1:
        errors.append(
            "MacScope.app and every inspected signed product must use the same "
            f"Apple Development signer; observed {signer_subjects!r}"
        )
    if configuration == "Release":
        _provenance, provenance_errors = validate_release_provenance(
            app_bundle,
            expected_source_commit=expected_source_commit,
            expected_source_tree=expected_source_tree,
        )
        errors.extend(provenance_errors)
    return errors


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        while chunk := stream.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


_APP_ROOT_IDENTITY_FIELDS = ("device", "inode", "mode", "nlink", "size", "mtime_ns")


def _closed_bundle_root_binding(
    bundle: Path,
    label: str,
) -> tuple[tuple[str, tuple[int, ...]] | None, list[str]]:
    try:
        metadata = bundle.lstat()
        canonical = bundle.resolve(strict=True)
        canonical_metadata = canonical.lstat()
    except OSError as error:
        return None, [f"{label} root is missing or inaccessible: {error}"]
    if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISDIR(metadata.st_mode):
        return None, [f"{label} root must be a non-symlink directory"]
    if (
        metadata.st_dev != canonical_metadata.st_dev
        or metadata.st_ino != canonical_metadata.st_ino
    ):
        return None, [f"{label} root canonical identity is unstable"]
    # A root-directory xattr update can change ctime without changing the
    # directory object or any signed content. Keep this exception local to the
    # app-root fence; regular-file reads still compare their complete metadata.
    # The collector independently verifies every file, mode and tree entry.
    root_identity = (
        metadata.st_dev,
        metadata.st_ino,
        metadata.st_mode,
        metadata.st_nlink,
        metadata.st_size,
        metadata.st_mtime_ns,
    )
    return (str(canonical), root_identity), []


def collect_installed_source_equality(
    source_app_bundle: Path,
    installed_app_bundle: Path,
) -> tuple[dict[str, str] | None, list[str]]:
    """Collect the candidate-compatible identity for two closed app bundles.

    The bundle and closed-tree digests deliberately reuse the Gate F candidate
    materializer.  The content identity covers every ordinary file, while the
    closed-tree identity additionally covers file modes and directory shape.
    Nested products, copied executables, resources, and plists therefore cannot
    drift behind a favorable code-signing result.
    """
    source_binding, source_binding_errors = _closed_bundle_root_binding(
        source_app_bundle,
        "source MacScope.app",
    )
    installed_binding, installed_binding_errors = _closed_bundle_root_binding(
        installed_app_bundle,
        "installed MacScope.app",
    )
    errors = [*source_binding_errors, *installed_binding_errors]
    if source_binding is None or installed_binding is None:
        return None, errors
    if (
        source_binding[0] == installed_binding[0]
        or source_binding[1][0:2] == installed_binding[1][0:2]
    ):
        errors.append(
            "source and installed MacScope.app bundles must be physically distinct "
            "directory objects"
        )
        return None, errors

    source_worker = (
        source_app_bundle
        / "Contents"
        / "XPCServices"
        / "AnalysisWorkerXPCService.xpc"
    )
    installed_worker = (
        installed_app_bundle
        / "Contents"
        / "XPCServices"
        / "AnalysisWorkerXPCService.xpc"
    )
    source_ai_worker = (
        source_app_bundle
        / "Contents"
        / "XPCServices"
        / "AIAgentWorkerXPCService.xpc"
    )
    installed_ai_worker = (
        installed_app_bundle
        / "Contents"
        / "XPCServices"
        / "AIAgentWorkerXPCService.xpc"
    )
    source_native_decompiler = (
        source_app_bundle
        / "Contents"
        / "XPCServices"
        / "NativeDecompilerXPCService.xpc"
    )
    installed_native_decompiler = (
        installed_app_bundle
        / "Contents"
        / "XPCServices"
        / "NativeDecompilerXPCService.xpc"
    )
    source_shell_broker = (
        source_app_bundle / "Contents" / "XPCServices" / "ShellBrokerXPCService.xpc"
    )
    installed_shell_broker = (
        installed_app_bundle / "Contents" / "XPCServices" / "ShellBrokerXPCService.xpc"
    )
    products = (
        (
            source_app_bundle,
            installed_app_bundle,
            "MacScope.app executable",
            EXPECTED_APP_IDENTIFIER,
        ),
        (
            source_worker,
            installed_worker,
            "AnalysisWorkerXPCService.xpc executable",
            EXPECTED_WORKER_IDENTIFIER,
        ),
        (
            source_ai_worker,
            installed_ai_worker,
            "AIAgentWorkerXPCService.xpc executable",
            EXPECTED_AI_WORKER_IDENTIFIER,
        ),
        (
            source_native_decompiler,
            installed_native_decompiler,
            "NativeDecompilerXPCService.xpc executable",
            EXPECTED_NATIVE_DECOMPILER_IDENTIFIER,
        ),
        (
            source_shell_broker,
            installed_shell_broker,
            "ShellBrokerXPCService.xpc executable",
            EXPECTED_SHELL_BROKER_IDENTIFIER,
        ),
    )
    source_app_executable_sha256: str | None = None
    installed_app_executable_sha256: str | None = None
    for index, (
        source_bundle,
        installed_bundle,
        label,
        expected_identifier,
    ) in enumerate(products):
        source_executable, source_errors = read_bundle_metadata(
            source_bundle,
            f"source {label}",
            expected_identifier,
        )
        installed_executable, installed_errors = read_bundle_metadata(
            installed_bundle,
            f"installed {label}",
            expected_identifier,
        )
        errors.extend(source_errors)
        errors.extend(installed_errors)
        if source_executable is None or installed_executable is None:
            continue
        try:
            source_hash = sha256_stable_artifact_file(
                source_executable,
                f"source {label}",
            )
            installed_hash = sha256_stable_artifact_file(
                installed_executable,
                f"installed {label}",
            )
        except ValueError as error:
            errors.append(str(error))
            continue
        if index == 0:
            source_app_executable_sha256 = source_hash
            installed_app_executable_sha256 = installed_hash
        if source_hash != installed_hash:
            errors.append(
                f"{label} SHA-256 must match the accepted source after installation; "
                f"source {source_hash}, installed {installed_hash}"
            )

    source_launch_agent = source_app_bundle / "Contents/MacOS/ShellBrokerLaunchAgent"
    installed_launch_agent = (
        installed_app_bundle / "Contents/MacOS/ShellBrokerLaunchAgent"
    )
    try:
        source_launch_agent_hash = sha256_stable_artifact_file(
            source_launch_agent,
            "source ShellBrokerLaunchAgent",
        )
        installed_launch_agent_hash = sha256_stable_artifact_file(
            installed_launch_agent,
            "installed ShellBrokerLaunchAgent",
        )
    except ValueError as error:
        errors.append(str(error))
    else:
        if source_launch_agent_hash != installed_launch_agent_hash:
            errors.append(
                "ShellBrokerLaunchAgent SHA-256 must match the accepted source after "
                f"installation; source {source_launch_agent_hash}, installed "
                f"{installed_launch_agent_hash}"
            )

    source_launch_agent = source_app_bundle / "Contents/MacOS/SourceExecutionRunner"
    installed_launch_agent = (
        installed_app_bundle / "Contents/MacOS/SourceExecutionRunner"
    )
    try:
        source_launch_agent_hash = sha256_stable_artifact_file(
            source_launch_agent,
            "source SourceExecutionRunner",
        )
        installed_launch_agent_hash = sha256_stable_artifact_file(
            installed_launch_agent,
            "installed SourceExecutionRunner",
        )
    except ValueError as error:
        errors.append(str(error))
    else:
        if source_launch_agent_hash != installed_launch_agent_hash:
            errors.append(
                "SourceExecutionRunner SHA-256 must match the accepted source after "
                f"installation; source {source_launch_agent_hash}, installed "
                f"{installed_launch_agent_hash}"
            )

    source_provenance, source_provenance_errors = validate_release_provenance(
        source_app_bundle
    )
    installed_provenance, installed_provenance_errors = validate_release_provenance(
        installed_app_bundle
    )
    errors.extend(
        f"source {error}" for error in source_provenance_errors
    )
    errors.extend(
        f"installed {error}" for error in installed_provenance_errors
    )
    if source_provenance is not None and installed_provenance is not None:
        for key in ("git_head_commit", "git_head_tree"):
            if source_provenance.get(key) != installed_provenance.get(key):
                errors.append(
                    f"installed sealed Release provenance {key} must match the "
                    "accepted source candidate"
                )

    source_digests = None
    installed_digests = None
    try:
        source_digests = bundle_tree_digests(source_app_bundle)
    except CandidateMaterializationError as error:
        errors.append(f"source MacScope.app closed-bundle identity failed: {error}")
    try:
        installed_digests = bundle_tree_digests(installed_app_bundle)
    except CandidateMaterializationError as error:
        errors.append(f"installed MacScope.app closed-bundle identity failed: {error}")

    authority: dict[str, str] | None = None
    if (
        source_digests is not None
        and installed_digests is not None
        and source_app_executable_sha256 is not None
        and installed_app_executable_sha256 is not None
    ):
        authority = {
            "release_bundle_sha256": source_digests.content_sha256,
            "release_closed_tree_sha256": source_digests.closed_tree_sha256,
            "release_executable_sha256": source_app_executable_sha256,
            "installed_bundle_sha256": installed_digests.content_sha256,
            "installed_closed_tree_sha256": installed_digests.closed_tree_sha256,
            "installed_executable_sha256": installed_app_executable_sha256,
        }
        if source_digests.content_sha256 != installed_digests.content_sha256:
            errors.append(
                "MacScope.app bundle SHA-256 must match the accepted source after "
                "installation; source "
                f"{source_digests.content_sha256}, installed "
                f"{installed_digests.content_sha256}"
            )
        if source_digests.closed_tree_sha256 != installed_digests.closed_tree_sha256:
            errors.append(
                "MacScope.app closed-tree SHA-256 must match the accepted source "
                "after installation; source "
                f"{source_digests.closed_tree_sha256}, installed "
                f"{installed_digests.closed_tree_sha256}"
            )
    observed_source_binding, source_binding_errors = _closed_bundle_root_binding(
        source_app_bundle,
        "source MacScope.app",
    )
    observed_installed_binding, installed_binding_errors = (
        _closed_bundle_root_binding(
            installed_app_bundle,
            "installed MacScope.app",
        )
    )
    errors.extend(source_binding_errors)
    errors.extend(installed_binding_errors)
    if (
        observed_source_binding != source_binding
        or observed_installed_binding != installed_binding
    ):
        differences = []
        for label, before, after in (
            ("source", source_binding, observed_source_binding),
            ("installed", installed_binding, observed_installed_binding),
        ):
            if before == after:
                continue
            if before is None or after is None:
                fields = ["root_unavailable"]
            else:
                fields = ["canonical_path"] if before[0] != after[0] else []
                fields.extend(name for name, old, new in zip(
                    _APP_ROOT_IDENTITY_FIELDS, before[1], after[1]
                ) if old != new)
            differences.append(f"{label}: {', '.join(fields)}")
        errors.append(
            "source or installed MacScope.app root changed during equality validation"
            f"; changed fields: {'; '.join(differences)}"
        )
    return authority, errors


def validate_installed_app_matches_source(
    source_app_bundle: Path,
    installed_app_bundle: Path,
) -> list[str]:
    """Require exact executable, content, mode, and directory-shape equality."""
    _, errors = collect_installed_source_equality(
        source_app_bundle,
        installed_app_bundle,
    )
    return errors


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--project-yml",
        type=Path,
        default=REPOSITORY_ROOT / "MacScope" / "project.yml",
    )
    parser.add_argument(
        "--ci-yml",
        type=Path,
        default=REPOSITORY_ROOT / ".github" / "workflows" / "ci.yml",
    )
    parser.add_argument(
        "--signing-identity-xcconfig",
        type=Path,
        default=REPOSITORY_ROOT / "MacScope" / "SigningIdentity.xcconfig",
    )
    parser.add_argument(
        "--dependency-roots-xcconfig",
        type=Path,
        default=REPOSITORY_ROOT / "MacScope" / "DependencyRoots.xcconfig",
    )
    parser.add_argument("--xcodeproj", type=Path)
    parser.add_argument("--build-environment", action="store_true")
    parser.add_argument(
        "--target",
        choices=tuple(EXPECTED_IDENTIFIERS_BY_TARGET),
        help="Signed target whose active build environment is being validated",
    )
    parser.add_argument("--active-toolchain", action="store_true")
    parser.add_argument("--record-generated-project-freshness", action="store_true")
    parser.add_argument(
        "--print-source-paths-digest",
        action="store_true",
        help="Print the folder-source path digest (captured by bootstrap before generation)",
    )
    parser.add_argument(
        "--expected-source-paths-digest",
        help="With --record-generated-project-freshness: refuse when the path list changed",
    )
    parser.add_argument("--app-bundle", type=Path)
    parser.add_argument(
        "--source-app-bundle",
        type=Path,
        help=(
            "Accepted source app to compare with --app-bundle after installation; "
            "the complete closed bundle and every mandatory embedded product must match"
        ),
    )
    parser.add_argument(
        "--configuration",
        choices=("Debug", "Release"),
        default="Debug",
        help="Build configuration for --app-bundle entitlement validation",
    )
    parser.add_argument(
        "--xcode-test-host-entitlements",
        action="store_true",
        help=(
            "Require the exact Xcode 27 Debug app-host XCTest entitlement injection "
            "profile; never valid for Release artifacts"
        ),
    )
    return parser.parse_args()


def main() -> int:
    arguments = parse_arguments()
    source_equality_authority: dict[str, str] | None = None
    if arguments.xcode_test_host_entitlements and arguments.app_bundle is None:
        print(
            "ERROR: --xcode-test-host-entitlements requires --app-bundle",
            file=sys.stderr,
        )
        return 2
    if (
        arguments.xcode_test_host_entitlements
        and arguments.source_app_bundle is not None
    ):
        print(
            "ERROR: --xcode-test-host-entitlements cannot be combined with "
            "--source-app-bundle; source-app comparison uses the ordinary artifact "
            "policy",
            file=sys.stderr,
        )
        return 2
    if arguments.print_source_paths_digest:
        print(generated_project_source_paths_digest(arguments.project_yml))
        return 0
    if arguments.record_generated_project_freshness:
        try:
            record_generated_project_freshness(
                arguments.project_yml, arguments.expected_source_paths_digest
            )
        except ValueError as error:
            print(f"ERROR: {error}", file=sys.stderr)
            return 1
        return 0
    if arguments.build_environment:
        freshness_errors = validate_generated_project_freshness(arguments.project_yml)
        if freshness_errors:
            print("ERROR: generated MacScope.xcodeproj is stale or unverified.", file=sys.stderr)
            for error in freshness_errors:
                print(f"  - {error}", file=sys.stderr)
            print("  - Run ./Scripts/bootstrap.sh, then retry the build.", file=sys.stderr)
            return 1
        # Bootstrap already validates the complete source/CI policy, every
        # generated target/configuration, and the selected Xcode 27 toolchain
        # before it records the freshness boundary checked above. Repeating
        # that immutable work in every signed target's build phase serialized
        # seven Python processes and 42 toolchain subprocesses per build. At
        # build time only the target-specific effective environment is new.
        build_errors = validate_build_environment(dict(os.environ), arguments.target)
        if build_errors:
            print("ERROR: active build signing policy is unstable:", file=sys.stderr)
            for error in build_errors:
                print(f"  - {error}", file=sys.stderr)
            return 1
        if _DEBUG_SIGNING_STAMP is not None:
            try:
                _DEBUG_SIGNING_STAMP.record("signing-environment", dict(os.environ))
            except Exception as error:  # the validation itself already passed
                print(
                    f"warning: signing-environment stamp not recorded: {error}",
                    file=sys.stderr,
                )
        return 0
    if arguments.source_app_bundle is not None and arguments.app_bundle is None:
        print(
            "ERROR: --source-app-bundle requires --app-bundle",
            file=sys.stderr,
        )
        return 2
    project_text = arguments.project_yml.read_text(encoding="utf-8")
    workflow_text = arguments.ci_yml.read_text(encoding="utf-8")
    signing_identity_text = arguments.signing_identity_xcconfig.read_text(
        encoding="utf-8"
    )
    dependency_roots_text = arguments.dependency_roots_xcconfig.read_text(
        encoding="utf-8"
    )
    candidate_source_identity: tuple[str, str] | None = None
    source_identity_errors: list[str] = []
    if arguments.app_bundle is not None and arguments.configuration == "Release":
        candidate_source_identity, source_identity_errors = repository_head_identity()
    expected_source_commit = (
        candidate_source_identity[0] if candidate_source_identity is not None else None
    )
    expected_source_tree = (
        candidate_source_identity[1] if candidate_source_identity is not None else None
    )
    errors = source_identity_errors + (
        validate_signing_identity_declaration(signing_identity_text)
        + validate_dependency_roots_config(project_text, dependency_roots_text)
        + validate_project_settings(project_text, project_directory=arguments.project_yml.absolute().parent)
        + validate_app_target_guard(project_text)
        + validate_release_provenance_project_phase(project_text)
        + validate_coretests_provenance_copy_project_phase(project_text)
        + validate_ci_override(workflow_text)
    )
    if arguments.xcodeproj is not None:
        errors.extend(validate_xcode_project(arguments.xcodeproj))
        errors.extend(
            validate_generated_project_provenance_phase(arguments.xcodeproj)
        )
    if arguments.active_toolchain:
        errors.extend(validate_active_toolchain(dict(os.environ)))
    if arguments.app_bundle is not None:
        errors.extend(
            validate_app_bundle(
                arguments.app_bundle,
                arguments.configuration,
                xcode_test_host=arguments.xcode_test_host_entitlements,
                expected_source_commit=expected_source_commit,
                expected_source_tree=expected_source_tree,
            )
        )
    if arguments.source_app_bundle is not None:
        errors.extend(
            validate_app_bundle(
                arguments.source_app_bundle,
                arguments.configuration,
                xcode_test_host=arguments.xcode_test_host_entitlements,
                expected_source_commit=expected_source_commit,
                expected_source_tree=expected_source_tree,
            )
        )
        source_equality_authority, equality_errors = collect_installed_source_equality(
            arguments.source_app_bundle,
            arguments.app_bundle,
        )
        errors.extend(equality_errors)
    if source_equality_authority is not None:
        print(canonical_text(source_equality_authority))
    if errors:
        print("ERROR: local signing policy is unstable:", file=sys.stderr)
        for error in errors:
            print(f"  - {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
