#!/usr/bin/env python3
"""Generate the code-signature-sealed MacScope Release provenance resource.

The Release path is deliberately fail-closed. It proves that every source or
resource selected by the app, tests, and embedded services is an ordinary blob
from the current HEAD with identical bytes. Non-Release builds receive only a
canonical, explicitly ineligible placeholder so ordinary development remains
fast and cannot be mistaken for qualification evidence.
"""

from __future__ import annotations

import argparse
from collections.abc import Iterator
import concurrent.futures
import hashlib
import importlib.util
import json
import os
import plistlib
import re
import secrets
import stat
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any, Callable


_golden_spec = importlib.util.spec_from_file_location(
    "macscope_native_golden_evidence",
    Path(__file__).resolve().parent / "native-decompiler-xpc/native_golden_evidence.py",
)
if _golden_spec is None or _golden_spec.loader is None:
    raise RuntimeError("native golden payload validator is unavailable")
_golden_validator = importlib.util.module_from_spec(_golden_spec)
_golden_spec.loader.exec_module(_golden_validator)
validate_golden_payload = _golden_validator.validate_golden_payload


SCHEMA_VERSION = 1
MAX_OUTPUT_BYTES = 16 * 1024
# The governed inventory intentionally includes the complete Ghostty, Zig, and
# SLEIGH/Ghidra source/resource closures. Its ten components and 198 declared
# root references currently expand to fewer than 78,000 unique files. Keep a
# distinct 90,000-file ceiling on that declared surface, then a 100,000-file
# ceiling on the combined top-level target closure. The real-inventory test
# preserves at least 10,000 and 20,000 files of reviewed growth headroom.
MAX_THIRD_PARTY_DECLARED_FILES = 90_000
# Bound on the selected Release input closure; keep >=20k headroom over the
# real project (80.6k selected after the Wave 1 package).
MAX_SELECTED_FILES = 120_000
MAX_SINGLE_INPUT_BYTES = 1024 * 1024 * 1024
MAX_TOTAL_INPUT_BYTES = 8 * 1024 * 1024 * 1024
MAX_XCODEGEN_ROOT_ENTRIES = 4_096
MAX_XCODEGEN_SPEC_BYTES = 1024 * 1024
MAX_SOURCE_EXPORT_HELPER_BYTES = 4 * 1024 * 1024
MAX_THIRD_PARTY_MANIFEST_BYTES = 2 * 1024 * 1024
MAX_MACHOKIT_MATERIALIZATION_MANIFEST_BYTES = 1024 * 1024
MAX_NATIVE_MATERIALIZATION_MANIFEST_BYTES = 2 * 1024 * 1024
MAX_PROVENANCE_TREE_ENTRIES = 100_000
MAX_PROVENANCE_TREE_DEPTH = 64
MAX_PROVENANCE_TREE_PATH_BYTES = 64 * 1024 * 1024
EXPECTED_APP_IDENTIFIER = "org.macscope.app"
EXPECTED_AI_WORKER_IDENTIFIER = "org.macscope.app.AIAgentWorker"
EXPECTED_SWIFT_LANGUAGE_VERSION = "6.0"
EXPECTED_DEPLOYMENT_TARGET = "27.0"
SELECTED_TARGETS = (
    "MacScopeApp",
    "AnalysisWorkerXPCService",
    "AIAgentWorkerXPCService",
    "ShellBrokerXPCService",
    "ShellBrokerLaunchAgent",
    "SourceExecutionRunner",
    "CoreTests",
)
NATIVE_DECOMPILER_XPC_TARGET = "NativeDecompilerXPCService"
ANALYSIS_CORE_TARGET = "MacScopeAnalysisCore"
DEBUGGER_CORE_TARGET = "MacScopeDebuggerCore"
PHASE2_TESTS_TARGET = "Phase2Tests"
EXPECTED_NATIVE_DECOMPILER_WRAPPER_VERSION = "dcp05c-v1"
NATIVE_DECOMPILER_XPC_INPUTS = (
    "MacScope/NativeDecompilerXPCService/Info.plist",
    "Scripts/native-decompiler-xpc",
    "Scripts/native-decompiler-direct/verify_sleigh_package.py",
    "Scripts/native-decompiler-direct/sleigh_package.py",
    "Tools/NativeDecompilerBridge",
)
NATIVE_DECOMPILER_GOLDEN_KEYS = _golden_validator.GOLDEN_KEYS
MANDATORY_INPUTS = (
    "MacScope/PARITY_CONTRACT.md",
    "MacScope/project.yml",
    "MacScope/DependencyRoots.xcconfig",
    "MacScope/SigningIdentity.xcconfig",
    "MacScope/Resources/Info.plist",
    "MacScope/AnalysisWorkerService/Info.plist",
    "MacScope/AIAgentWorkerService/Info.plist",
    "MacScope/ShellBrokerService/Info.plist",
    "MacScope/ShellBrokerService/LaunchAgentInfo.plist",
    "MacScope/ShellBrokerService/LaunchAgent.plist",
    "THIRD_PARTY_COMPONENTS.yml",
    "THIRD_PARTY_NOTICES.md",
    "docs/dependencies/LicenseDecision.md",
    "Scripts/dependencies/third_party_components.schema.json",
    "Scripts/dependencies/validate_offline_build_surface.py",
    "Scripts/dependencies/validate_policy_consistency.py",
    "Scripts/dependencies/validate_third_party_components.py",
    "Scripts/dependencies/materialize_machokit.py",
    "Scripts/dependencies/stage_verified_ghostty_surface.py",
    "Scripts/generate_release_build_provenance.py",
    "Scripts/machokit_source_identity.py",
    "Scripts/verify_machokit_analysis_worker_identity.py",
    "Scripts/source_export_provenance.py",
    "Scripts/check_local_signing_policy.py",
    "Scripts/project_freshness.py",
    "Scripts/xcode_project_json.py",
    "Scripts/generate_xcode_json_project.py",
)
XCODEGEN_REPOSITORY_SIBLING_PATHS = (
    "ThirdParty/SwiftAssemblyVendor/Sources",
    "ThirdParty/Lumen",
    "ThirdParty/REA",
    "Packages/RecoveryKit",
)
REA_REPOSITORY_SOURCE_PATHS = frozenset({
    "../ThirdParty/REA/generated/REAEmbeddedIdentity.swift",
    "../ThirdParty/REA/generated/MacScopeREAKernel.js",
    "../ThirdParty/REA/licenses",
})
HEX_SHA1 = re.compile(r"^[0-9a-f]{40}$")
HEX_SHA256 = re.compile(r"^[0-9a-f]{64}$")
SAFE_BUILD_VALUE = re.compile(r"^[A-Za-z0-9._+\-]+$")
THIRD_PARTY_COMPONENT_KEYS = {
    "id",
    "name",
    "canonical_repository",
    "approval",
    "integration_mode",
    "license_expression",
    "pin",
    "tracked_paths",
    "materialization",
    "license_paths",
    "license_sha256",
    "notice_paths",
    "patches_path",
    "targets",
    "review",
    "notes",
}
THIRD_PARTY_MATERIALIZATION_KEYS = {
    "script",
    "network_allowed",
    "implicit_build_invocation",
    "expected_untracked_root",
}
THIRD_PARTY_COMPONENT_ID_PATTERN = re.compile(r"^[a-z0-9][a-z0-9-]{1,63}$")
MACHOKIT_EXPECTED_IDENTITY = {
    "version": "0.52.2",
    "revision": "773e10797abc53914b94c2ee8c6f40f5da0b06eb",
    "source_archive_sha256": (
        "2e6d429f248ac3f01b896379c3c77518858a2213ef3da0d89939d112de9fd945"
    ),
    "upstream_tree_sha256": (
        "0a0bdc104b7f20c3f34ef595e113152cfc78ec496e96e14cb4957cf4d81dd038"
    ),
    "materialization_tree_sha256": (
        "e6796548485d32a183c3e1641989d637f5f6344c9e5af5a9cfbb83f549007950"
    ),
    "governed_source_identity": (
        "b2f928cfc635b3a539129d1dbd50464c9d218c4a815553bc4b710ac813a790ea"
    ),
}

GHOSTTY_SURFACE_COMPILATION_CONDITION = "MACSCOPE_FULL_GHOSTTY_SURFACE"
GHOSTTY_SURFACE_MANIFEST_KEYS = (
    "schema",
    "source_revision",
    "source_tree",
    "source_sha256",
    "zig_version",
    "zig_archive_sha256",
    "zig_toolchain_tree_sha256",
    "zig_toolchain_receipt_sha256",
    "external_io_abi_version",
    "networking",
    "residual_network_imports",
    "libxev_package_id",
    "libxev_patch_sha256",
    "raw_package_store_sha256",
    "package_store_sha256",
    "architecture",
    "library_identifier",
    "build_profile_sha256",
    "info_plist_sha256",
    "archive_sha256",
    "header_sha256",
    "module_map_sha256",
)
GHOSTTY_SURFACE_BUILD_FLAGS = (
    "-Demit-lib-vt=false",
    "-Dapp-runtime=none",
    "-Drenderer=metal",
    "-Dsentry=false",
    "-Di18n=false",
    "-Dmacscope-external-io-only=true",
    "-Demit-xcframework=true",
    "-Demit-macos-app=false",
    "-Demit-exe=false",
    "-Demit-test-exe=false",
    "-Demit-unicode-table-gen=false",
    "-Demit-bench=false",
    "-Demit-helpgen=false",
    "-Demit-docs=false",
    "-Demit-terminfo=false",
    "-Demit-termcap=false",
    "-Demit-themes=false",
    "-Demit-webdata=false",
    "-Dxcframework-target=native",
    "-Doptimize=ReleaseFast",
)


def _ghostty_surface_build_profile_sha256() -> str:
    digest = hashlib.sha256()
    for flag in GHOSTTY_SURFACE_BUILD_FLAGS:
        digest.update(flag.encode("utf-8"))
        digest.update(b"\0")
    return digest.hexdigest()


EXPECTED_GHOSTTY_SURFACE_MANIFEST_FIELDS = {
    "schema": "3",
    "source_revision": "f64f4aca2c29b554d111b36c3d946a9bddd159ff",
    "source_tree": "de6cd65b35a423d5d6854c6af3a90be20a52d7eb",
    "source_sha256": "ead5d48a8cda07addb59af1f35c6c9f7226bbdbd977b7330afd9714ecec6d8ab",
    "zig_version": "0.16.0",
    "zig_archive_sha256": "b23d70deaa879b5c2d486ed3316f7eaa53e84acf6fc9cc747de152450d401489",
    "zig_toolchain_tree_sha256": "521e2ef7605386b8da70aa3d6c3d135b344ee319c4b5a280470f8c07265ace43",
    "zig_toolchain_receipt_sha256": "55f99da3a6d9cfed280b2dbbe2ec87776cc3dc28b7a5d71cab9adabc8f8bdc94",
    "external_io_abi_version": "1",
    "networking": "disabled",
    "residual_network_imports": "_bind,_connect,_listen,_recvmsg,_socket",
    "libxev_package_id": "libxev-0.0.0-86vtcwIRFADbH4hk-EjROXxlrKIRPQdA41XiTSytYO-F",
    "libxev_patch_sha256": "f26b438413c1ec2022f5e6701daa8d00920c91bc7da9f6add5d2e80662e0ff8d",
    "raw_package_store_sha256": "70147cac57344d68a8dd812b7dd85b1d0eae984da531064e424128f937105d0f",
    "package_store_sha256": "13f8e6d6cc075fc5c13bb211e624c2a4311ff47cae414b44b7d509830adbf84c",
    "architecture": "arm64",
    "library_identifier": "macos-arm64",
    "build_profile_sha256": _ghostty_surface_build_profile_sha256(),
}
GHOSTTY_SURFACE_STAGED_DESCRIPTOR = "STAGED_GHOSTTY_SURFACE.json"
GHOSTTY_SURFACE_STAGED_DESCRIPTOR_MAX_BYTES = 64 * 1024
GHOSTTY_SURFACE_STAGED_LEAVES = (
    ("archive", "libghostty-internal.a", "archive_sha256"),
    ("header", "Headers/ghostty.h", "header_sha256"),
    ("module_map", "Headers/module.modulemap", "module_map_sha256"),
)
GHOSTTY_SURFACE_STAGED_LEAF_FIELDS = {
    relative_path: manifest_field
    for _, relative_path, manifest_field in GHOSTTY_SURFACE_STAGED_LEAVES
}


class ProvenanceError(RuntimeError):
    """A Release build cannot produce qualification-eligible evidence."""


class ProvenanceArguments:
    def __init__(
        self,
        *,
        repository_root: Path,
        project_yml: Path,
        project_file_path: Path,
        configuration: str,
        architectures: str,
        deployment_target: str,
        sdk_name: str,
        sdk_version: str,
        sdk_build: str,
        developer_dir: Path,
        swift_executable: Path,
        output: Path,
        debug_source_identity: str = "runtime-only",
        native_decompiler_golden_result: Path | None = None,
        native_decompiler_live_test_condition: str = "",
        swift_active_compilation_conditions: str = "",
        other_swift_flags: str = "",
        ghostty_source_dir: Path | None = None,
        ghostty_surface_manifest: Path | None = None,
        ghostty_surface_staged_root: Path | None = None,
        sleigh_materialization_root: Path | None = None,
        machokit_materialization_root: Path | None = None,
        sleigh_materialization_verifier: (
            Callable[[Path], dict[str, Any]] | None
        ) = None,
        machokit_identity_verifier: Callable[[Path], dict[str, str]] | None = None,
        analysis_worker_executable: Path | None = None,
        machokit_compiled_identity_verifier: (
            Callable[[Path], dict[str, str]] | None
        ) = None,
    ) -> None:
        self.repository_root = repository_root
        self.project_yml = project_yml
        self.project_file_path = project_file_path
        self.configuration = configuration
        self.debug_source_identity = debug_source_identity
        self.architectures = architectures
        self.deployment_target = deployment_target
        self.sdk_name = sdk_name
        self.sdk_version = sdk_version
        self.sdk_build = sdk_build
        self.developer_dir = developer_dir
        self.swift_executable = swift_executable
        self.output = output
        self.native_decompiler_golden_result = native_decompiler_golden_result
        self.native_decompiler_live_test_condition = native_decompiler_live_test_condition
        self.swift_active_compilation_conditions = swift_active_compilation_conditions
        self.other_swift_flags = other_swift_flags
        self.ghostty_source_dir = ghostty_source_dir
        self.ghostty_surface_manifest = ghostty_surface_manifest
        self.ghostty_surface_staged_root = ghostty_surface_staged_root
        self.sleigh_materialization_root = sleigh_materialization_root
        self.machokit_materialization_root = machokit_materialization_root
        # This override exists only for hermetic provenance fixtures. Production
        # CLI callers always load the source-sealed strict SLEIGH verifier.
        self.sleigh_materialization_verifier = sleigh_materialization_verifier
        # The override exists only for hermetic provenance fixtures. The CLI and
        # every production build use the independently anchored verifier below.
        self.machokit_identity_verifier = machokit_identity_verifier
        self.analysis_worker_executable = analysis_worker_executable
        # This override is only a hermetic-test seam. Production CLI callers
        # always load the independently pinned verifier from the source seal.
        self.machokit_compiled_identity_verifier = machokit_compiled_identity_verifier


ToolRunner = Callable[[list[str], Path], subprocess.CompletedProcess[str]]


def run_tool(command: list[str], cwd: Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        command,
        cwd=cwd,
        check=False,
        capture_output=True,
        text=True,
    )


def run_git(
    repository_root: Path,
    arguments: list[str],
    *,
    text: bool = False,
) -> subprocess.CompletedProcess:
    return subprocess.run(
        ["/usr/bin/git", *arguments],
        cwd=repository_root,
        check=False,
        capture_output=True,
        text=text,
    )


def required_git_text(repository_root: Path, arguments: list[str]) -> str:
    result = run_git(repository_root, arguments, text=True)
    if result.returncode != 0:
        diagnostic = result.stderr.strip() or "git command failed"
        raise ProvenanceError(diagnostic)
    value = result.stdout.strip()
    if not value or "\n" in value or "\r" in value:
        raise ProvenanceError(f"git {' '.join(arguments)} returned invalid output")
    return value


class SourceAuthority:
    def __init__(
        self,
        *,
        head_commit: str,
        head_tree: str,
        sealed_records: dict[str, dict[str, object]] | None,
    ) -> None:
        self.head_commit = head_commit
        self.head_tree = head_tree
        self.sealed_records = sealed_records

    @property
    def sealed_paths(self) -> set[str] | None:
        return None if self.sealed_records is None else set(self.sealed_records)


def _metadata_only_export_verifiers(namespace: dict[str, object]) -> None:
    """Replace the helper's per-file byte re-hash with a metadata check.

    Used only for the Debug trusted-digest mode (see
    TRUSTED_SEALED_DIGESTS_ENVIRONMENT). Every manifest, provenance, commit
    object, tree reconstruction and dependency-contract check still runs; only
    the two full SHA-256/blob re-hashes of every exported file are replaced by
    type, link-count, size and permission checks, because the qualifier has
    already verified those bytes and re-verifies them after the last Xcode action.
    """
    stable = ("st_dev", "st_ino", "st_mode", "st_nlink", "st_size", "st_mtime_ns", "st_ctime_ns")
    export_error = namespace.get("SourceExportError", ProvenanceError)

    def binding(root: Path, relative: str) -> os.stat_result:
        if relative.startswith("/") or any(part in {"", ".", ".."} for part in relative.split("/")):
            raise export_error(f"unsafe exported path: {relative}")
        metadata = (root / relative).lstat()
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_nlink != 1:
            raise export_error(f"source input must be one ordinary file: {relative}")
        return metadata

    def verify_metadata(root: Path, records) -> dict[str, tuple[int, ...]]:
        bindings: dict[str, tuple[int, ...]] = {}
        for record in records:
            relative = str(record["path"])
            metadata = binding(root, relative)
            expected_permissions = 0o755 if record["mode"] == "100755" else 0o644
            if metadata.st_size != record["size"] or stat.S_IMODE(metadata.st_mode) != expected_permissions:
                raise export_error(f"exported source does not match its manifest: {relative}")
            bindings[relative] = tuple(getattr(metadata, field) for field in stable)
        return bindings

    def revalidate_metadata(root: Path, bindings: dict[str, tuple[int, ...]]) -> None:
        for relative, expected in bindings.items():
            metadata = binding(root, relative)
            if tuple(getattr(metadata, field) for field in stable) != expected:
                raise export_error(f"exported source changed during final revalidation: {relative}")

    namespace["_verify_exported_records"] = verify_metadata
    namespace["_revalidate_exported_record_bindings"] = revalidate_metadata


def _load_source_export_authority(
    repository_root: Path,
    *,
    canonical_git: bool = False,
    canonical_lfs_entries: dict[str, tuple[str, str]] | None = None,
    trust_verified_export: bool = False,
) -> tuple[dict[str, object], dict[str, dict[str, object]]]:
    helper = Path(__file__).resolve(strict=True).with_name(
        "source_export_provenance.py"
    )
    try:
        metadata = helper.lstat()
    except FileNotFoundError as error:
        raise ProvenanceError("sealed source export helper is missing") from error
    if (
        not stat.S_ISREG(metadata.st_mode)
        or stat.S_ISLNK(metadata.st_mode)
        or metadata.st_nlink != 1
    ):
        raise ProvenanceError(
            "trusted sealed source export helper must be an ordinary singly linked file"
        )
    stable_fields = (
        "st_dev",
        "st_ino",
        "st_mode",
        "st_nlink",
        "st_size",
        "st_mtime_ns",
        "st_ctime_ns",
    )
    expected_binding = tuple(getattr(metadata, field) for field in stable_fields)
    descriptor: int | None = None
    try:
        descriptor = os.open(
            helper,
            os.O_RDONLY
            | getattr(os, "O_NOFOLLOW", 0)
            | getattr(os, "O_CLOEXEC", 0),
        )
        opened = os.fstat(descriptor)
        if (
            tuple(getattr(opened, field) for field in stable_fields)
            != expected_binding
            or not stat.S_ISREG(opened.st_mode)
            or opened.st_nlink != 1
            or opened.st_size > MAX_SOURCE_EXPORT_HELPER_BYTES
        ):
            raise ProvenanceError(
                "trusted sealed source export helper changed before verification"
            )
        payload = bytearray()
        while len(payload) <= MAX_SOURCE_EXPORT_HELPER_BYTES:
            chunk = os.read(
                descriptor,
                min(1024 * 1024, MAX_SOURCE_EXPORT_HELPER_BYTES + 1 - len(payload)),
            )
            if not chunk:
                break
            payload.extend(chunk)
        after_read = os.fstat(descriptor)
        if (
            len(payload) != opened.st_size
            or len(payload) > MAX_SOURCE_EXPORT_HELPER_BYTES
            or tuple(getattr(after_read, field) for field in stable_fields)
            != expected_binding
        ):
            raise ProvenanceError(
                "trusted sealed source export helper changed while it was read"
            )
        namespace: dict[str, object] = {
            "__name__": "macscope_source_export_provenance",
            "__file__": str(helper),
            "__package__": None,
        }
        exec(
            compile(bytes(payload), str(helper), "exec", dont_inherit=True),
            namespace,
        )
        if canonical_lfs_entries is not None:
            # Reuse the exporter's exact allowlist, canonical parser and bounds.
            parse_pointer = namespace.get("_parse_lfs_pointer")
            allowed_paths = namespace.get("LFS_PATHS")
            if not callable(parse_pointer) or not isinstance(allowed_paths, frozenset):
                raise ProvenanceError("source export helper has no canonical LFS policy")
            provenance, records = {}, {}
            for relative in sorted(allowed_paths.intersection(canonical_lfs_entries)):
                mode, object_id = canonical_lfs_entries[relative]
                size_result = run_git(repository_root, ["cat-file", "-s", object_id], text=True)
                if size_result.returncode != 0 or not size_result.stdout.strip().isdigit():
                    raise ProvenanceError("could not inspect canonical LFS blob size")
                blob_size = int(size_result.stdout.strip())
                if blob_size > 1024:
                    continue  # An ordinary committed payload still requires exact blob identity.
                blob = run_git(repository_root, ["cat-file", "blob", object_id])
                if blob.returncode != 0 or len(blob.stdout) != blob_size:
                    raise ProvenanceError("could not read canonical LFS pointer")
                pointer = parse_pointer(blob.stdout, blob_size, relative)
                if pointer is not None:
                    digest, size = pointer
                    records[relative] = {"mode": mode, "sha256": digest, "size": size}
        elif canonical_git:
            canonical_git_file_entries = namespace.get("canonical_git_file_entries")
            if not callable(canonical_git_file_entries):
                raise ProvenanceError("source export helper has no canonical Git entry point")
            entries = canonical_git_file_entries(repository_root)
            provenance = {}
            records = {
                relative: {"mode": mode, "blob_oid": object_id}
                for relative, (mode, object_id) in entries.items()
            }
            if len(records) != len(entries):
                raise ProvenanceError("canonical Git entries contain duplicate source paths")
        else:
            if trust_verified_export:
                _metadata_only_export_verifiers(namespace)
            load_verified_export = namespace.get("load_verified_export")
            if not callable(load_verified_export):
                raise ProvenanceError(
                    "sealed source export helper has no verifier entry point"
                )
            provenance, records = load_verified_export(
                repository_root,
                require_closed_tree=False,
            )
        after_execution = os.fstat(descriptor)
        observed_metadata = helper.lstat()
        if (
            tuple(getattr(after_execution, field) for field in stable_fields)
            != expected_binding
            or tuple(getattr(observed_metadata, field) for field in stable_fields)
            != expected_binding
        ):
            raise ProvenanceError(
                "trusted sealed source export helper changed during verification"
            )
    except ProvenanceError:
        raise
    except Exception as error:
        raise ProvenanceError(f"sealed source export is invalid: {error}") from error
    finally:
        if descriptor is not None:
            os.close(descriptor)
    if not isinstance(provenance, dict) or not isinstance(records, dict):
        raise ProvenanceError("sealed source export helper returned invalid evidence")
    return provenance, records



# Explicit operator admission consumes a completed qualification. It does not
# assert that old source or dependency leaves have been freshly verified.
_ADMITTED_RELEASE: dict[str, Any] | None = None


_admission_spec = importlib.util.spec_from_file_location(
    "macscope_release_publication", Path(__file__).resolve().parent / "qualification/release_provenance_admission.py")
if _admission_spec is None or _admission_spec.loader is None:
    raise RuntimeError("Release publication admission helper is unavailable")
_release_admission = importlib.util.module_from_spec(_admission_spec)
_admission_spec.loader.exec_module(_release_admission)


def _receipt_json(path: Path, label: str, limit: int = 32 * 1024 * 1024) -> dict[str, Any]:
    if _ADMITTED_RELEASE is not None and _ADMITTED_RELEASE.get("current_release"):
        _ADMITTED_RELEASE["lease"].file(path)
    if not path.is_absolute() or path.resolve(strict=True) != path:
        raise ProvenanceError(f"{label} must have an absolute direct path")
    value = json.loads(read_bounded_regular_file(path, limit, label))
    if not isinstance(value, dict):
        raise ProvenanceError(f"{label} must be a JSON object")
    return value


def _admitted_source_records(root: Path, identity: dict[str, Any]) -> dict[str, dict[str, Any]]:
    provenance = _receipt_json(root / "SOURCE_PROVENANCE.json", "admitted source provenance")
    if provenance != identity or provenance.get("repository_clean") is not True:
        raise ProvenanceError("qualification source identity differs from admitted provenance")
    files = _receipt_json(root / "SOURCE_FILES.json", "admitted source file records")
    raw = files.get("files")
    if not isinstance(raw, list) or len(raw) != identity.get("source_file_count"):
        raise ProvenanceError("admitted source file count differs")
    records = {}
    for entry in raw:
        if not isinstance(entry, dict):
            raise ProvenanceError("admitted source record is malformed")
        path = entry.get("path")
        if (not isinstance(path, str) or Path(path).is_absolute() or ".." in Path(path).parts
                or path in records or entry.get("mode") not in {"100644", "100755"}
                or not isinstance(entry.get("sha256"), str)
                or HEX_SHA256.fullmatch(entry["sha256"]) is None):
            raise ProvenanceError("admitted source record identity is malformed")
        records[path] = entry
    return records


def _admitted_release(repository_root: Path) -> dict[str, Any] | None:
    global _ADMITTED_RELEASE
    location = os.environ.get("MACSCOPE_QUALIFICATION_INPUTS_RECEIPT")
    if not location:
        return None
    if _ADMITTED_RELEASE is not None:
        if _ADMITTED_RELEASE["root"] != repository_root:
            raise ProvenanceError("admitted Release source root changed")
        return _ADMITTED_RELEASE
    receipt_path = Path(location)
    receipt = _receipt_json(receipt_path, "qualification inputs receipt")
    run = receipt_path.parent
    if receipt_path.name != "QUALIFICATION_INPUTS.json" or receipt.get("schema_version") != 4:
        raise ProvenanceError("unsupported qualification inputs admission")
    if receipt.get("build_source_root") != str(repository_root) or repository_root != run / "source":
        raise ProvenanceError("qualification admission does not bind the build source/run")
    identity = receipt.get("source_identity")
    if not isinstance(identity, dict) or any(
        not isinstance(identity.get(key), str) or HEX_SHA1.fullmatch(identity[key]) is None
        for key in ("git_head_commit", "git_head_tree")
    ):
        raise ProvenanceError("qualification source identity is malformed")
    records = _admitted_source_records(repository_root, identity)
    if os.environ.get("MACSCOPE_CACHE_RELEASE_ADMISSION"):
        import sys
        sys.path.insert(0, str(Path(__file__).resolve().parent / "qualification"))
        import cache_release_inputs
        _ADMITTED_RELEASE = cache_release_inputs.admit_current(repository_root, receipt_path, receipt, records, _receipt_json)
        return _ADMITTED_RELEASE
    if os.environ.get("MACSCOPE_NATIVE_RELEASE_ADMISSION"):
        _ADMITTED_RELEASE = _release_admission.admit_current(
            repository_root, receipt_path, receipt, records, _receipt_json)
        return _ADMITTED_RELEASE
    overlay_path = os.environ.get("MACSCOPE_RELEASE_PROJECT_OVERLAY_RECEIPT")
    if not overlay_path:
        raise ProvenanceError("receipt reuse requires the explicit provenance-tool overlay receipt")
    overlay = _receipt_json(Path(overlay_path), "Release project overlay receipt")
    if (overlay.get("schema_version") != 1 or overlay.get("change_scope") != "receipt-consuming-build-phases"
            or overlay.get("original_source_root") != str(repository_root)
            or overlay.get("original_project_path") != str(repository_root / "MacScope/MacScope.xcodeproj/project.xcproj")
            or overlay.get("helper_path") != str(Path(__file__).resolve(strict=True))
            or not isinstance(overlay.get("helper_commit"), str)
            or HEX_SHA1.fullmatch(overlay["helper_commit"]) is None):
        raise ProvenanceError("Release project overlay admission is not bound to this helper/source")
    events = _receipt_json(run / "DEPENDENCY_CACHE_EVENTS.json", "dependency admission events")
    if events.get("source") != {"commit": identity["git_head_commit"], "tree": identity["git_head_tree"]}:
        raise ProvenanceError("dependency admission source differs")
    admitted = {event.get("component"): event for event in events.get("events", [])
                if isinstance(event, dict) and event.get("status") in {"verified-hit", "verified-published"}}
    for component, view in (("ghostty-surface", receipt.get("ghostty_surface_source_dir")),
                            ("sleigh-native-source", str(Path(receipt["sleigh_materialization_root"]).parent))):
        if component not in admitted or admitted[component].get("run_view") != view:
            raise ProvenanceError(f"missing matching completed dependency admission: {component}")
    _ADMITTED_RELEASE = {"root": repository_root, "receipt": receipt, "run": run,
                         "records": records, "overlay": overlay, "receipt_path": receipt_path}
    return _ADMITTED_RELEASE


def resolve_source_authority(
    repository_root: Path, *, trust_verified_export: bool = False
) -> SourceAuthority:
    admitted = _admitted_release(repository_root)
    if admitted is not None:
        identity = admitted["receipt"]["source_identity"]
        return SourceAuthority(head_commit=identity["git_head_commit"],
                               head_tree=identity["git_head_tree"],
                               sealed_records=admitted["records"])
    files_record = repository_root / "SOURCE_FILES.json"
    provenance_record = repository_root / "SOURCE_PROVENANCE.json"
    if files_record.exists() != provenance_record.exists():
        raise ProvenanceError("sealed source export records are incomplete")
    has_export = files_record.exists()

    top_level_result = run_git(
        repository_root,
        ["rev-parse", "--show-toplevel"],
        text=True,
    )
    if top_level_result.returncode == 0:
        top_level_text = top_level_result.stdout.strip()
        if not top_level_text or "\n" in top_level_text or "\r" in top_level_text:
            raise ProvenanceError("Git worktree root is malformed")
        top_level = Path(top_level_text).resolve(strict=True)
        if top_level != repository_root:
            raise ProvenanceError("repository root does not match the Git worktree root")
        require_clean_repository(repository_root)
        head_commit = required_git_text(repository_root, ["rev-parse", "HEAD"])
        head_tree = required_git_text(repository_root, ["rev-parse", "HEAD^{tree}"])
        records = None
        if has_export:
            provenance, records = _load_source_export_authority(repository_root, trust_verified_export=trust_verified_export)
            if (
                provenance.get("git_head_commit") != head_commit
                or provenance.get("git_head_tree") != head_tree
            ):
                raise ProvenanceError("Git and sealed source-export identities disagree")
    elif has_export:
        provenance, records = _load_source_export_authority(repository_root, trust_verified_export=trust_verified_export)
        head_commit = provenance.get("git_head_commit")
        head_tree = provenance.get("git_head_tree")
    else:
        diagnostic = (
            top_level_result.stderr.strip()
            if isinstance(top_level_result.stderr, str)
            else top_level_result.stderr.decode(errors="replace").strip()
        )
        raise ProvenanceError(diagnostic or "source root is neither Git nor a sealed export")

    if (
        not isinstance(head_commit, str)
        or not isinstance(head_tree, str)
        or HEX_SHA1.fullmatch(head_commit) is None
        or HEX_SHA1.fullmatch(head_tree) is None
    ):
        raise ProvenanceError("qualification requires 40-character Git commit/tree IDs")
    return SourceAuthority(
        head_commit=head_commit,
        head_tree=head_tree,
        sealed_records=records,
    )


def validated_build_value(label: str, value: str) -> str:
    if not value or len(value) > 128 or SAFE_BUILD_VALUE.fullmatch(value) is None:
        raise ProvenanceError(f"{label} is missing or malformed")
    return value


def validate_arguments(arguments: ProvenanceArguments) -> None:
    if arguments.debug_source_identity not in {"runtime-only", "source-qualified"}:
        raise ProvenanceError("Debug source identity mode must be runtime-only or source-qualified")
    if arguments.configuration not in {"Debug", "Release"}:
        raise ProvenanceError("configuration must be Debug or Release")
    if (
        arguments.configuration == "Release"
        and arguments.native_decompiler_live_test_condition != ""
    ):
        raise ProvenanceError(
            "Release qualification requires an empty native decompiler live-test condition"
        )
    if arguments.configuration == "Release":
        for label, root in (
            ("MACSCOPE_GHOSTTY_SOURCE_DIR", arguments.ghostty_source_dir),
            (
                "--ghostty-surface-staged-root",
                arguments.ghostty_surface_staged_root,
            ),
            (
                "MACSCOPE_SLEIGH_MATERIALIZATION_ROOT",
                arguments.sleigh_materialization_root,
            ),
            (
                "MACSCOPE_MACHOKIT_MATERIALIZATION_ROOT",
                arguments.machokit_materialization_root,
            ),
        ):
            if root is None or not root.is_absolute():
                raise ProvenanceError(f"{label} must be an absolute dependency root")
            try:
                resolved = root.resolve(strict=True)
            except OSError as error:
                raise ProvenanceError(f"{label} cannot be resolved: {error}") from error
            if not resolved.is_dir():
                raise ProvenanceError(f"{label} must resolve to an existing directory")
        surface_manifest = arguments.ghostty_surface_manifest
        if surface_manifest is None or not surface_manifest.is_absolute():
            raise ProvenanceError("--ghostty-surface-manifest must be an absolute path")
        try:
            manifest_metadata = surface_manifest.lstat()
        except OSError as error:
            raise ProvenanceError(
                f"--ghostty-surface-manifest cannot be inspected: {error}"
            ) from error
        if (
            stat.S_ISLNK(manifest_metadata.st_mode)
            or not stat.S_ISREG(manifest_metadata.st_mode)
            or manifest_metadata.st_nlink != 1
        ):
            raise ProvenanceError(
                "--ghostty-surface-manifest must be an ordinary singly linked file"
            )
        worker_executable = arguments.analysis_worker_executable
        if worker_executable is None or not worker_executable.is_absolute():
            raise ProvenanceError(
                "AnalysisWorkerXPCService executable must be an absolute build artifact path"
            )
        live_symbol = "MACSCOPE_NATIVE_DECOMPILER_LIVE_XPC_TESTING"
        if live_symbol in arguments.swift_active_compilation_conditions:
            raise ProvenanceError(
                "Release qualification forbids the native decompiler live-test Swift condition"
            )
        if live_symbol in arguments.other_swift_flags:
            raise ProvenanceError(
                "Release qualification forbids native decompiler live-test Swift flags"
            )
        surface_conditions = arguments.swift_active_compilation_conditions.split()
        if surface_conditions.count(GHOSTTY_SURFACE_COMPILATION_CONDITION) != 1:
            raise ProvenanceError(
                "Release qualification requires exactly one "
                f"{GHOSTTY_SURFACE_COMPILATION_CONDITION} Swift compilation condition"
            )
    if arguments.architectures != "arm64":
        raise ProvenanceError("qualification builds must be arm64-only")
    validated_build_value("ARCHS", arguments.architectures)
    deployment = validated_build_value(
        "MACOSX_DEPLOYMENT_TARGET",
        arguments.deployment_target,
    )
    if deployment != EXPECTED_DEPLOYMENT_TARGET:
        raise ProvenanceError(
            f"deployment target must be {EXPECTED_DEPLOYMENT_TARGET}"
        )
    sdk_name = validated_build_value("SDK_NAME", arguments.sdk_name)
    sdk_version = validated_build_value("SDK_VERSION", arguments.sdk_version)
    validated_build_value("SDK_PRODUCT_BUILD_VERSION", arguments.sdk_build)
    if sdk_name != f"macosx{sdk_version}" or not sdk_version.startswith("27."):
        raise ProvenanceError("qualification builds require the macOS 27 SDK")


def canonical_json(payload: dict[str, object]) -> bytes:
    encoded = (
        json.dumps(
            payload,
            ensure_ascii=True,
            allow_nan=False,
            sort_keys=True,
            separators=(",", ":"),
        )
        + "\n"
    ).encode("utf-8")
    if len(encoded) > MAX_OUTPUT_BYTES:
        raise ProvenanceError("provenance resource exceeds its fixed size bound")
    return encoded


def write_atomic(path: Path, payload: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=f".{path.name}.",
        dir=path.parent,
    )
    temporary_path = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(payload)
            stream.flush()
            os.fsync(stream.fileno())
        temporary_path.chmod(0o644)
        os.replace(temporary_path, path)
    finally:
        try:
            temporary_path.unlink()
        except FileNotFoundError:
            pass


def ineligible_payload(arguments: ProvenanceArguments) -> dict[str, object]:
    return {
        "schema_version": SCHEMA_VERSION,
        "qualification_eligible": False,
        "configuration": arguments.configuration,
        "git_head_commit": None,
        "git_head_tree": None,
        "repository_clean": False,
        "selected_build_inputs_sha256": None,
        "project_yml_sha256": None,
        "third_party_manifest_sha256": None,
        "third_party_notices_sha256": None,
        "third_party_component_ids": [],
        "third_party_component_count": 0,
        "third_party_distribution_status": None,
        "third_party_public_distribution_approved": False,
        "xcodegen_version": None,
        "xcode_version": None,
        "xcode_build": None,
        "swift_compiler_version": None,
        "swift_target_triple": None,
        "sdk_name": arguments.sdk_name,
        "sdk_version": arguments.sdk_version,
        "sdk_build": arguments.sdk_build,
        "swift_language_version": EXPECTED_SWIFT_LANGUAGE_VERSION,
        "architecture": arguments.architectures,
        "deployment_target": arguments.deployment_target,
        "app_bundle_identifier": EXPECTED_APP_IDENTIFIER,
        "ai_worker_bundle_identifier": EXPECTED_AI_WORKER_IDENTIFIER,
    }


def debug_runtime_payload(arguments: ProvenanceArguments) -> dict[str, object]:
    """Bind the signed embedded runtime without claiming Release qualification."""
    app_root, _result_path = _derived_embedded_native_decompiler_paths(arguments)
    if os.environ.get("MACSCOPE_NATIVE_DEBUG_CONTINUATION_RECEIPT"):
        helper = arguments.repository_root / "Scripts/native-decompiler-xpc/debug_native_receipt.py"
        specification = importlib.util.spec_from_file_location("macscope_debug_native_receipt", helper)
        if specification is None or specification.loader is None:
            raise ProvenanceError("Debug continuation receipt consumer is unavailable")
        consumer = importlib.util.module_from_spec(specification)
        specification.loader.exec_module(consumer)
        admitted = consumer.admit(arguments.repository_root.resolve(strict=True), _result_path)
        payload = ineligible_payload(arguments)
        golden = admitted["golden"]
        payload.update(xcode_version=golden["xcodeVersion"], xcode_build=golden["xcodeBuild"],
                       swift_compiler_version=golden["swiftCompilerVersion"], swift_target_triple=golden["swiftTargetTriple"])
        payload.update(consumer.runtime_evidence(admitted, _result_path))
        return payload
    snapshot = _capture_embedded_native_decompiler_snapshot(app_root)
    golden_bytes = snapshot["golden_bytes"]
    assert isinstance(golden_bytes, bytes)
    try:
        golden = json.loads(golden_bytes)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ProvenanceError("embedded native decompiler golden result is malformed") from error
    if not isinstance(golden, dict):
        raise ProvenanceError("embedded native decompiler golden result must be an object")

    tools = {
        "xcodegen_version": None,
        "xcode_version": golden.get("xcodeVersion"),
        "xcode_build": golden.get("xcodeBuild"),
        "swift_compiler_version": golden.get("swiftCompilerVersion"),
        "swift_target_triple": golden.get("swiftTargetTriple"),
    }
    if any(
        not isinstance(tools[key], str) or not tools[key]
        for key in (
            "xcode_version",
            "xcode_build",
            "swift_compiler_version",
            "swift_target_triple",
        )
    ):
        raise ProvenanceError("embedded native decompiler golden toolchain is incomplete")

    payload = ineligible_payload(arguments)
    payload.update(tools)
    payload.update(
        native_decompiler_golden_evidence(
            arguments,
            wrapper_source_sha256=golden.get("wrapperGitRevision"),
            golden_source_sha256=golden.get("goldenSourceSHA256"),
            tools=tools,
        )
    )
    # Routine Debug binds the signed runtime without walking the source closure.
    # Source-qualified Debug is deliberate opt-in and still never confers Release eligibility.
    if arguments.debug_source_identity == "runtime-only":
        return payload
    # Debug remains ineligible. Publish source identities only when the same clean
    # Git/sealed authority and selected-input checks used by Release can prove them.
    try:
        repository_root = arguments.repository_root.resolve(strict=True)
        project_yml = arguments.project_yml.resolve(strict=True)
        if project_yml != repository_root / "MacScope/project.yml":
            raise ProvenanceError("Debug source identity requires MacScope/project.yml")
        trust_requested = (
            arguments.configuration == "Debug"
            and os.environ.get(TRUSTED_SEALED_DIGESTS_ENVIRONMENT) == TRUSTED_SEALED_DIGESTS_VALUE
        )
        authority = resolve_source_authority(repository_root, trust_verified_export=trust_requested)
        trust_sealed = trust_requested and authority.sealed_records is not None
        project_text = project_yml.read_text(encoding="utf-8")
        selected_paths = selected_source_paths(repository_root, project_yml, project_text,
            sealed_paths=authority.sealed_paths)
        selected_hashes = selected_input_hashes(repository_root, selected_paths,
            sealed_records=authority.sealed_records, trust_sealed_digests=trust_sealed)
        if selected_source_paths(repository_root, project_yml, project_yml.read_text(encoding="utf-8"),
            sealed_paths=authority.sealed_paths) != selected_paths:
            raise ProvenanceError("Debug selected build input membership changed")
        if selected_input_hashes(repository_root, selected_paths,
            sealed_records=authority.sealed_records, trust_sealed_digests=trust_sealed) != selected_hashes:
            raise ProvenanceError("Debug selected build inputs changed")
        final_authority = resolve_source_authority(
            repository_root, trust_verified_export=trust_requested)
        if (final_authority.head_commit != authority.head_commit
            or final_authority.head_tree != authority.head_tree):
            raise ProvenanceError("Debug source authority changed")
    except (ProvenanceError, OSError, UnicodeError):
        # Dirty, absent, or unverifiable source authority is valid for runtime-only
        # Debug evidence; consumers needing source identity must still refuse nulls.
        pass
    else:
        payload.update({
            "git_head_commit": authority.head_commit,
            "git_head_tree": authority.head_tree,
            "selected_build_inputs_sha256": selected_inputs_digest(selected_hashes),
        })
    return payload


def strip_yaml_comment(value: str) -> str:
    in_single = False
    in_double = False
    escaped = False
    for index, character in enumerate(value):
        if escaped:
            escaped = False
            continue
        if character == "\\" and in_double:
            escaped = True
            continue
        if character == "'" and not in_double:
            in_single = not in_single
            continue
        if character == '"' and not in_single:
            in_double = not in_double
            continue
        if character == "#" and not in_single and not in_double:
            return value[:index].rstrip()
    return value.rstrip()


def yaml_scalar(value: str) -> str:
    stripped = strip_yaml_comment(value).strip()
    if not stripped:
        raise ProvenanceError("project.yml contains an empty required scalar")
    if stripped.startswith('"'):
        try:
            decoded = json.loads(stripped)
        except json.JSONDecodeError as error:
            raise ProvenanceError(f"project.yml contains invalid quoted text: {error}")
        if not isinstance(decoded, str):
            raise ProvenanceError("project.yml scalar must be text")
        return decoded
    if stripped.startswith("'") and stripped.endswith("'"):
        return stripped[1:-1].replace("''", "'")
    if any(character in stripped for character in "\r\n\0"):
        raise ProvenanceError("project.yml scalar contains control text")
    return stripped


def parse_scalar_mapping(project_text: str) -> dict[tuple[str, ...], str]:
    values: dict[tuple[str, ...], str] = {}
    stack: list[tuple[int, str]] = []
    mapping_pattern = re.compile(r"^(?P<indent> *)(?P<key>[A-Za-z0-9_]+):(?P<value>.*)$")
    for line in project_text.splitlines():
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        match = mapping_pattern.match(line)
        if match is None:
            continue
        indentation = len(match.group("indent"))
        while stack and stack[-1][0] >= indentation:
            stack.pop()
        key = match.group("key")
        raw_value = strip_yaml_comment(match.group("value")).strip()
        path = tuple(item[1] for item in stack) + (key,)
        if raw_value:
            values[path] = yaml_scalar(raw_value)
        else:
            stack.append((indentation, key))
    return values


def direct_target_range(lines: list[str], target: str) -> tuple[int, int]:
    targets_markers = [index for index, line in enumerate(lines) if line == "targets:"]
    if len(targets_markers) != 1:
        raise ProvenanceError("project.yml must contain exactly one top-level targets mapping")
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
        raise ProvenanceError(f"project.yml must define exactly one {target} target")
    start = markers[0]
    end = targets_end
    for index in range(start + 1, targets_end):
        line = lines[index]
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        indentation = len(line) - len(line.lstrip(" "))
        if indentation <= 2:
            end = index
            break
    return start, end


def target_source_entries(
    project_text: str,
    target: str,
) -> list[tuple[str, tuple[str, ...]]]:
    lines = project_text.splitlines()
    target_start, target_end = direct_target_range(lines, target)
    source_markers = [
        index
        for index in range(target_start + 1, target_end)
        if lines[index] == "    sources:"
    ]
    if len(source_markers) != 1:
        raise ProvenanceError(f"{target} must define exactly one direct sources list")
    source_start = source_markers[0]
    source_end = target_end
    for index in range(source_start + 1, target_end):
        line = lines[index]
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        indentation = len(line) - len(line.lstrip(" "))
        if indentation <= 4:
            source_end = index
            break

    entries: list[tuple[str, tuple[str, ...]]] = []
    index = source_start + 1
    while index < source_end:
        line = lines[index]
        if not line.strip() or line.lstrip().startswith("#"):
            index += 1
            continue
        path_match = re.fullmatch(r"      - path:(.*)", line)
        if path_match is None:
            raise ProvenanceError(f"{target} sources must use explicit path entries")
        source_path = yaml_scalar(path_match.group(1))
        excludes: list[str] = []
        entry_end = source_end
        probe = index + 1
        while probe < source_end:
            probe_line = lines[probe]
            if probe_line.startswith("      - path:"):
                entry_end = probe
                break
            probe += 1
        exclude_markers = [
            probe
            for probe in range(index + 1, entry_end)
            if lines[probe] == "        excludes:"
        ]
        if len(exclude_markers) > 1:
            raise ProvenanceError(f"{target} source entry repeats excludes")
        if exclude_markers:
            exclude_index = exclude_markers[0] + 1
            while exclude_index < entry_end:
                exclude_line = lines[exclude_index]
                if not exclude_line.strip() or exclude_line.lstrip().startswith("#"):
                    exclude_index += 1
                    continue
                exclude_match = re.fullmatch(r"          -(.*)", exclude_line)
                if exclude_match is None:
                    break
                excludes.append(yaml_scalar(exclude_match.group(1)))
                exclude_index += 1
        entries.append((source_path, tuple(excludes)))
        index = entry_end
    if not entries:
        raise ProvenanceError(f"{target} sources list must not be empty")
    return entries


def relative_source_path(value: str) -> Path:
    path = Path(value)
    if path.is_absolute() or not path.parts or ".." in path.parts:
        raise ProvenanceError(f"source path must stay under MacScope: {value!r}")
    return path


def is_excluded(relative_path: str, patterns: tuple[str, ...]) -> bool:
    for pattern in patterns:
        normalized = pattern.removeprefix("./")
        if normalized.startswith("**/"):
            suffix = normalized[3:]
            if (
                not suffix
                or "/" in suffix
                or any(character in suffix for character in "*?[")
            ):
                raise ProvenanceError("unsupported wildcard in project source exclude")
            if relative_path == suffix or relative_path.endswith(f"/{suffix}"):
                return True
            continue
        if normalized.endswith("/**"):
            prefix = normalized[:-3].rstrip("/")
            if not prefix or any(character in prefix for character in "*?["):
                raise ProvenanceError("unsupported wildcard in project source exclude")
            if relative_path == prefix or relative_path.startswith(f"{prefix}/"):
                return True
            continue
        if any(character in normalized for character in "*?["):
            raise ProvenanceError("unsupported wildcard in project source exclude")
        if relative_path == normalized:
            return True
    return False


def walk_selected_path(path: Path) -> Iterator[Path]:
    try:
        metadata = path.lstat()
    except FileNotFoundError:
        raise ProvenanceError(f"selected build input is missing: {path.name}")
    if stat.S_ISREG(metadata.st_mode) or stat.S_ISLNK(metadata.st_mode):
        yield path
        return
    if not stat.S_ISDIR(metadata.st_mode):
        yield path
        return

    with os.scandir(path) as entries:
        children = sorted(entries, key=lambda item: os.fsencode(item.name))
    for entry in children:
        yield from walk_selected_path(Path(entry.path))


def is_ignored_untracked_build_metadata(
    repository_root: Path,
    relative_path: str,
) -> bool:
    if Path(relative_path).suffix not in {".pyc", ".pyo"} and Path(relative_path).name != ".DS_Store":
        return False

    tracked = run_git(
        repository_root,
        ["ls-files", "--error-unmatch", "--", relative_path],
    )
    if tracked.returncode == 0:
        return False
    if tracked.returncode != 1:
        raise ProvenanceError("could not classify selected build metadata in Git")

    ignored = run_git(repository_root, ["check-ignore", "-q", "--", relative_path])
    if ignored.returncode == 0:
        return True
    if ignored.returncode == 1:
        return False
    raise ProvenanceError("could not evaluate build metadata ignore policy")


class DuplicateThirdPartyManifestKey(ValueError):
    pass


def _third_party_object_without_duplicate_keys(
    pairs: list[tuple[str, Any]],
) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise DuplicateThirdPartyManifestKey(key)
        result[key] = value
    return result


def load_third_party_manifest(repository_root: Path) -> tuple[dict[str, Any], bytes]:
    path = repository_root / "THIRD_PARTY_COMPONENTS.yml"
    payload = read_bounded_regular_file(
        path,
        MAX_THIRD_PARTY_MANIFEST_BYTES,
        "THIRD_PARTY_COMPONENTS.yml",
    )
    try:
        manifest = json.loads(
            payload,
            object_pairs_hook=_third_party_object_without_duplicate_keys,
        )
    except DuplicateThirdPartyManifestKey as error:
        raise ProvenanceError(
            f"third-party manifest contains duplicate key: {error.args[0]}"
        )
    except json.JSONDecodeError as error:
        raise ProvenanceError(
            "THIRD_PARTY_COMPONENTS.yml must remain JSON-compatible YAML: "
            f"line {error.lineno}, column {error.colno}: {error.msg}"
        )
    if not isinstance(manifest, dict) or set(manifest) != {
        "schema_version",
        "distribution_policy",
        "components",
    }:
        raise ProvenanceError("third-party manifest has an unsupported top-level schema")
    if manifest["schema_version"] != 1:
        raise ProvenanceError("third-party manifest schema_version must be 1")
    distribution = manifest["distribution_policy"]
    if not isinstance(distribution, dict) or set(distribution) != {
        "status",
        "public_distribution_approved",
        "decision_record",
    }:
        raise ProvenanceError("third-party distribution policy is malformed")
    if distribution["status"] not in {
        "private-development-only",
        "distribution-approved",
    } or type(distribution["public_distribution_approved"]) is not bool:
        raise ProvenanceError("third-party distribution policy values are malformed")
    if distribution["public_distribution_approved"] != (
        distribution["status"] == "distribution-approved"
    ):
        raise ProvenanceError("third-party distribution policy fields disagree")
    decision_record = distribution["decision_record"]
    _manifest_relative_path(decision_record, "distribution_policy.decision_record")

    components = manifest["components"]
    if not isinstance(components, list) or not (1 <= len(components) <= 512):
        raise ProvenanceError("third-party components must contain 1..512 entries")
    observed_ids: set[str] = set()
    for index, component in enumerate(components):
        if not isinstance(component, dict) or set(component) != THIRD_PARTY_COMPONENT_KEYS:
            raise ProvenanceError(
                f"third-party component {index} has an unsupported schema"
            )
        component_id = component["id"]
        if (
            not isinstance(component_id, str)
            or THIRD_PARTY_COMPONENT_ID_PATTERN.fullmatch(component_id) is None
            or component_id in observed_ids
        ):
            raise ProvenanceError("third-party component id is malformed or duplicated")
        observed_ids.add(component_id)
        for key in ("tracked_paths", "license_paths", "notice_paths"):
            values = component[key]
            if (
                not isinstance(values, list)
                or not values
                or len(values) != len(set(values))
            ):
                raise ProvenanceError(
                    f"{component_id}.{key} must be a non-empty unique array"
                )
            for value in values:
                _manifest_relative_path(value, f"{component_id}.{key}")
        _manifest_relative_path(
            component["patches_path"], f"{component_id}.patches_path"
        )
        materialization = component["materialization"]
        if (
            not isinstance(materialization, dict)
            or set(materialization) != THIRD_PARTY_MATERIALIZATION_KEYS
        ):
            raise ProvenanceError(f"{component_id}.materialization is malformed")
        materializer = materialization["script"]
        if materializer is not None:
            _manifest_relative_path(
                materializer, f"{component_id}.materialization.script"
            )
        if (
            type(materialization["network_allowed"]) is not bool
            or type(materialization["implicit_build_invocation"]) is not bool
            or materialization["implicit_build_invocation"]
        ):
            raise ProvenanceError(
                f"{component_id}.materialization policy values are malformed"
            )
    return manifest, payload


def _manifest_relative_path(value: Any, label: str) -> str:
    if not isinstance(value, str) or not value or len(value) > 512:
        raise ProvenanceError(f"{label} must be a bounded repository-relative path")
    path = Path(value)
    if path.is_absolute() or ".." in path.parts or path.as_posix() != value:
        raise ProvenanceError(f"{label} must be a canonical repository-relative path")
    return value


def third_party_declared_paths(repository_root: Path) -> set[str]:
    manifest, _ = load_third_party_manifest(repository_root)
    selected: set[str] = set()
    distribution = manifest["distribution_policy"]
    path_values: list[tuple[Any, str]] = [
        (
            distribution["decision_record"],
            "distribution_policy.decision_record",
        )
    ]
    for component in manifest["components"]:
        component_id = component["id"]
        for key in ("tracked_paths", "license_paths", "notice_paths"):
            path_values.extend(
                (value, f"{component_id}.{key}") for value in component[key]
            )
        path_values.append(
            (component["patches_path"], f"{component_id}.patches_path")
        )
        materializer = component["materialization"]["script"]
        if materializer is not None:
            path_values.append(
                (materializer, f"{component_id}.materialization.script")
            )

    for raw_path, label in path_values:
        relative = _manifest_relative_path(raw_path, label)
        candidate = repository_root / relative
        for file_path in walk_selected_path(candidate):
            try:
                repository_relative = file_path.relative_to(repository_root).as_posix()
            except ValueError:
                raise ProvenanceError("third-party declared path escaped repository root")
            selected.add(repository_relative)
            if len(selected) > MAX_THIRD_PARTY_DECLARED_FILES:
                raise ProvenanceError("third-party declared path count exceeds fixed bound")
    return selected


def selected_source_paths(
    repository_root: Path,
    project_yml: Path,
    project_text: str,
    *,
    sealed_paths: set[str] | None = None,
) -> set[str]:
    source_base = project_yml.parent
    selected: set[str] = set()
    native_target_marker = f"  {NATIVE_DECOMPILER_XPC_TARGET}:"
    native_inventory_present = (
        native_target_marker in project_text.splitlines()
        or (repository_root / "MacScope/NativeDecompilerXPCService").exists()
        or (repository_root / "Scripts/native-decompiler-xpc").exists()
    )
    selected_targets = SELECTED_TARGETS
    # D12 layer 3: sources the app excludes from its globs because they compile once in the
    # MacScopeAnalysisCore static library stay selected through that target.
    if f"  {ANALYSIS_CORE_TARGET}:" in project_text.splitlines():
        selected_targets = (ANALYSIS_CORE_TARGET,) + selected_targets
    if f"  {DEBUGGER_CORE_TARGET}:" in project_text.splitlines():
        selected_targets = (DEBUGGER_CORE_TARGET,) + selected_targets
    if f"  {PHASE2_TESTS_TARGET}:" in project_text.splitlines():
        selected_targets += (PHASE2_TESTS_TARGET,)
    if native_inventory_present:
        selected_targets += (NATIVE_DECOMPILER_XPC_TARGET,)

    for target in selected_targets:
        for source_value, excludes in target_source_entries(project_text, target):
            if source_value in REA_REPOSITORY_SOURCE_PATHS:
                source_root = repository_root / source_value.removeprefix("../")
            else:
                source_relative = relative_source_path(source_value)
                source_root = source_base / source_relative
            for candidate in walk_selected_path(source_root):
                relative_to_source = (
                    candidate.relative_to(source_root).as_posix()
                    if source_root.is_dir()
                    else candidate.name
                )
                if source_root.is_dir() and is_excluded(relative_to_source, excludes):
                    continue
                try:
                    repository_relative = candidate.relative_to(repository_root).as_posix()
                except ValueError:
                    raise ProvenanceError("selected build input escaped repository root")
                selected.add(repository_relative)
                if len(selected) > MAX_SELECTED_FILES:
                    raise ProvenanceError("selected build input count exceeds fixed bound")
    selected.update(MANDATORY_INPUTS)
    selected.update(_release_admission.SOURCE_INPUTS)
    first_party_manifest = repository_root / "FIRST_PARTY_COMPONENTS.json"
    if first_party_manifest.exists() or first_party_manifest.is_symlink():
        selected.update((
            "FIRST_PARTY_COMPONENTS.json",
            "Scripts/dependencies/first_party_components.py",
            "Scripts/dependencies/materialize_lumen_submodule.py",
        ))
    if native_inventory_present:
        for relative_root in NATIVE_DECOMPILER_XPC_INPUTS:
            input_root = repository_root / relative_root
            for candidate in walk_selected_path(input_root):
                try:
                    repository_relative = candidate.relative_to(repository_root).as_posix()
                except ValueError:
                    raise ProvenanceError(
                        "native decompiler XPC input escaped repository root"
                    )
                selected.add(repository_relative)
                if len(selected) > MAX_SELECTED_FILES:
                    raise ProvenanceError(
                        "selected build input count exceeds fixed bound"
                    )
    selected.update(third_party_declared_paths(repository_root))
    if re.search(r"(?m)^    path: ['\"]?\.\./ThirdParty/Lumen['\"]?\s*$", project_text):
        # Select canonical package files, never its .git administration or an
        # ignored SwiftPM build cache. The sealer owns gitlink validation for
        # both live Git checkouts and independently verified Git-less exports.
        canonical_paths = set(head_blobs(repository_root)) if sealed_paths is None else sealed_paths
        package_paths = {path for path in canonical_paths if path.startswith("ThirdParty/Lumen/")}
        if "ThirdParty/Lumen/Package.swift" not in package_paths or ".gitmodules" not in canonical_paths:
            raise ProvenanceError("declared Lumen package is absent from canonical source authority")
        selected.update(package_paths)
        selected.add(".gitmodules")
    if sealed_paths is None:
        selected = {
            relative_path
            for relative_path in selected
            if not is_ignored_untracked_build_metadata(repository_root, relative_path)
        }
    else:
        selected = {
            relative_path
            for relative_path in selected
            if (Path(relative_path).suffix not in {".pyc", ".pyo"}
                and Path(relative_path).name != ".DS_Store")
            or relative_path in sealed_paths
        }
    if len(selected) > MAX_SELECTED_FILES:
        raise ProvenanceError("selected build input count exceeds fixed bound")
    return selected


def require_clean_repository(repository_root: Path) -> None:
    for arguments, label in (
        (["diff", "--quiet", "--"], "unstaged changes"),
        (["diff", "--cached", "--quiet", "--"], "staged changes"),
    ):
        result = run_git(repository_root, arguments)
        if result.returncode == 1:
            raise ProvenanceError(f"Release provenance requires a clean repository: {label}")
        if result.returncode != 0:
            raise ProvenanceError(f"could not verify repository {label}")
    status_result = run_git(
        repository_root,
        ["status", "--porcelain=v1", "-z", "--untracked-files=all"],
    )
    if status_result.returncode != 0:
        raise ProvenanceError("could not verify repository status")
    if status_result.stdout:
        raise ProvenanceError(
            "Release provenance requires a clean repository with no untracked files"
        )


def head_blob(repository_root: Path, relative_path: str) -> tuple[str, str]:
    result = run_git(
        repository_root,
        ["ls-tree", "-z", "HEAD", "--", relative_path],
    )
    if result.returncode != 0:
        raise ProvenanceError(f"could not inspect HEAD input {relative_path!r}")
    records = [record for record in result.stdout.split(b"\0") if record]
    if len(records) != 1 or b"\t" not in records[0]:
        raise ProvenanceError(
            f"selected build input is not an ordinary HEAD blob: {relative_path!r}"
        )
    metadata, observed_path = records[0].split(b"\t", 1)
    fields = metadata.split(b" ")
    expected_path = os.fsencode(relative_path)
    if (
        len(fields) != 3
        or fields[0] not in {b"100644", b"100755"}
        or fields[1] != b"blob"
        or observed_path != expected_path
    ):
        raise ProvenanceError(
            f"selected build input is not an ordinary HEAD blob: {relative_path!r}"
        )
    object_identifier = fields[2].decode("ascii", errors="strict")
    return fields[0].decode("ascii"), object_identifier


def head_blobs(repository_root: Path) -> dict[str, tuple[str, str]]:
    result = run_git(repository_root, ["ls-tree", "-r", "-z", "HEAD", "--"])
    if result.returncode != 0:
        raise ProvenanceError("could not inspect HEAD tree")

    if any(record.startswith(b"160000 commit ") for record in result.stdout.split(b"\0")):
        # Share the exporter's exact module/commit/tree validation instead of
        # inventing a second, less strict submodule authority for direct builds.
        _provenance, records = _load_source_export_authority(repository_root, canonical_git=True)
        return {path: (str(record["mode"]), str(record["blob_oid"])) for path, record in records.items()}

    entries: dict[str, tuple[str, str]] = {}
    for record in result.stdout.split(b"\0"):
        if not record:
            continue
        if b"\t" not in record:
            raise ProvenanceError("HEAD tree contained malformed metadata")
        metadata, observed_path = record.split(b"\t", 1)
        fields = metadata.split(b" ")
        if len(fields) != 3 or fields[1] != b"blob":
            raise ProvenanceError("HEAD tree contained malformed blob metadata")
        mode = fields[0].decode("ascii", errors="strict")
        object_identifier = fields[2].decode("ascii", errors="strict")
        if HEX_SHA1.fullmatch(object_identifier) is None:
            raise ProvenanceError("HEAD tree contained malformed object identifier")
        path = observed_path.decode("utf-8", errors="surrogateescape")
        if path in entries:
            raise ProvenanceError("HEAD tree contained duplicate path metadata")
        entries[path] = (mode, object_identifier)
    return entries


def sha256_file(path: Path) -> tuple[bytes, int]:
    before = path.lstat()
    if not stat.S_ISREG(before.st_mode):
        raise ProvenanceError(f"selected build input must be a regular file: {path.name!r}")
    if before.st_size > MAX_SINGLE_INPUT_BYTES:
        raise ProvenanceError("selected build input exceeds fixed single-file bound")
    digest = hashlib.sha256()
    observed_size = 0
    descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    with os.fdopen(descriptor, "rb") as stream:
        opened = os.fstat(stream.fileno())
        if (opened.st_dev, opened.st_ino) != (before.st_dev, before.st_ino):
            raise ProvenanceError("selected build input identity changed before reading")
        while chunk := stream.read(1024 * 1024):
            observed_size += len(chunk)
            if observed_size > MAX_SINGLE_INPUT_BYTES:
                raise ProvenanceError("selected build input grew beyond fixed bound")
            digest.update(chunk)
        after_descriptor = os.fstat(stream.fileno())
    after_path = path.lstat()
    stable_fields = (
        "st_dev",
        "st_ino",
        "st_mode",
        "st_size",
        "st_mtime_ns",
        "st_ctime_ns",
    )
    if any(
        getattr(before, field) != getattr(after_descriptor, field)
        or getattr(before, field) != getattr(after_path, field)
        for field in stable_fields
    ):
        raise ProvenanceError("selected build input changed while being hashed")
    return digest.digest(), observed_size


def local_object_hashes(
    repository_root: Path,
    relative_paths: list[str],
) -> dict[str, str]:
    for relative_path in relative_paths:
        if "\n" in relative_path or "\r" in relative_path:
            raise ProvenanceError("selected build input path contains unsupported control text")
    result = subprocess.run(
        ["/usr/bin/git", "hash-object", "--no-filters", "--stdin-paths"],
        cwd=repository_root,
        input="".join(f"{relative_path}\n" for relative_path in relative_paths),
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        diagnostic = result.stderr.strip() or "git hash-object failed"
        raise ProvenanceError(f"could not hash selected inputs: {diagnostic}")
    observed = result.stdout.splitlines()
    if len(observed) != len(relative_paths):
        raise ProvenanceError("git hash-object returned unexpected selected-input count")
    hashes: dict[str, str] = {}
    for relative_path, object_identifier in zip(relative_paths, observed):
        if HEX_SHA1.fullmatch(object_identifier) is None:
            raise ProvenanceError("git hash-object returned malformed object identifier")
        hashes[relative_path] = object_identifier
    return hashes


def _parallel_sha256_files(
    repository_root: Path,
    sorted_paths: list[str],
) -> dict[str, tuple[bytes, int]]:
    """SHA-256 every selected file with the unchanged per-file checks.

    hashlib releases the GIL while digesting, so a thread pool turns the
    serial ~70 s walk of the ~1.7 GB selected closure into parallel I/O and
    hashing. Results are identical to serial hashing; any per-file error is
    re-raised (the first failing path in sorted order).
    """
    workers = max(1, min(16, os.cpu_count() or 1))
    if workers == 1 or len(sorted_paths) < 64:
        return {path: sha256_file(repository_root / path) for path in sorted_paths}
    with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as pool:
        results = pool.map(lambda path: sha256_file(repository_root / path), sorted_paths, chunksize=64)
        return dict(zip(sorted_paths, results))


# Debug-only opt-in set by the qualifier for smoke/focused-test gates (never
# full-test, release or Gate F). The qualifier has already verified the staged
# sealed export before Xcode and fully re-verifies it after the last Xcode
# action, so the Debug phase takes digests from the sealed manifest and checks
# only per-file metadata instead of re-hashing ~1.7 GB twice.
TRUSTED_SEALED_DIGESTS_ENVIRONMENT = "MACSCOPE_PROVENANCE_SEALED_DIGESTS"
TRUSTED_SEALED_DIGESTS_VALUE = "trust-verified-export"


def _sealed_metadata_digests(
    repository_root: Path,
    sorted_paths: list[str],
    sealed_records: dict[str, dict[str, object]],
) -> dict[str, tuple[bytes, int]]:
    results: dict[str, tuple[bytes, int]] = {}
    for relative_path in sorted_paths:
        sealed = sealed_records.get(relative_path)
        if not isinstance(sealed, dict) or not isinstance(sealed.get("sha256"), str):
            raise ProvenanceError(
                f"selected build input is absent from the sealed source export: {relative_path!r}"
            )
        metadata = (repository_root / relative_path).lstat()
        executable = bool(metadata.st_mode & 0o100)
        if (
            not stat.S_ISREG(metadata.st_mode)
            or metadata.st_size != sealed.get("size")
            or executable != (sealed.get("mode") == "100755")
        ):
            raise ProvenanceError(
                f"selected build input metadata differs from the sealed source export: {relative_path!r}"
            )
        try:
            digest = bytes.fromhex(str(sealed["sha256"]))
        except ValueError as error:
            raise ProvenanceError("sealed source export digest is malformed") from error
        if len(digest) != hashlib.sha256().digest_size:
            raise ProvenanceError("sealed source export digest is malformed")
        results[relative_path] = (digest, metadata.st_size)
    return results


def selected_input_hashes(
    repository_root: Path,
    relative_paths: set[str],
    *,
    sealed_records: dict[str, dict[str, object]] | None = None,
    trust_sealed_digests: bool = False,
) -> dict[str, bytes]:
    admitted = _admitted_release(repository_root)
    if admitted is not None:
        if sealed_records != admitted["records"] or not relative_paths.issubset(sealed_records):
            raise ProvenanceError("selected inputs differ from admitted source membership")
        return {path: bytes.fromhex(sealed_records[path]["sha256"]) for path in relative_paths}
    hashes: dict[str, bytes] = {}
    total_bytes = 0
    sorted_paths = sorted(relative_paths, key=os.fsencode)
    head_entries = head_blobs(repository_root) if sealed_records is None else None
    lfs_records: dict[str, dict[str, object]] = {}
    if head_entries is not None:
        _, lfs_records = _load_source_export_authority(
            repository_root,
            canonical_lfs_entries={path: head_entries[path] for path in sorted_paths if path in head_entries},
        )
    local_objects = (
        local_object_hashes(repository_root, sorted_paths)
        if sealed_records is None
        else None
    )
    if trust_sealed_digests and sealed_records is not None:
        file_digests = _sealed_metadata_digests(repository_root, sorted_paths, sealed_records)
    else:
        file_digests = _parallel_sha256_files(repository_root, sorted_paths)
    for relative_path in sorted_paths:
        candidate = repository_root / relative_path
        digest, size = file_digests[relative_path]
        if sealed_records is None:
            assert head_entries is not None and local_objects is not None
            head_entry = head_entries.get(relative_path)
            if head_entry is None or head_entry[0] not in {"100644", "100755"}:
                raise ProvenanceError(
                    f"selected build input is not an ordinary HEAD blob: {relative_path!r}"
                )
            lfs_record = lfs_records.get(relative_path)
            if lfs_record is not None:
                if size != lfs_record["size"] or digest.hex() != lfs_record["sha256"]:
                    raise ProvenanceError(
                        f"selected LFS input differs from its canonical pointer: {relative_path!r}"
                    )
                metadata = candidate.lstat()
                expected_mode = 0o755 if head_entry[0] == "100755" else 0o644
                if metadata.st_nlink != 1 or stat.S_IMODE(metadata.st_mode) != expected_mode:
                    raise ProvenanceError("selected LFS input must be a singly linked file with canonical permissions")
            elif local_objects.get(relative_path) != head_entry[1]:
                raise ProvenanceError(
                    f"selected build input bytes differ from HEAD: {relative_path!r}"
                )
        else:
            sealed = sealed_records.get(relative_path)
            if (
                not isinstance(sealed, dict)
                or sealed.get("mode") not in {"100644", "100755"}
                or sealed.get("size") != size
                or sealed.get("sha256") != digest.hex()
            ):
                raise ProvenanceError(
                    f"selected build input is absent from or differs from the sealed source export: {relative_path!r}"
                )
        total_bytes += size
        if total_bytes > MAX_TOTAL_INPUT_BYTES:
            raise ProvenanceError("selected build inputs exceed fixed aggregate bound")
        hashes[relative_path] = digest
    return hashes


def selected_inputs_digest(entries: dict[str, bytes]) -> str:
    digest = hashlib.sha256()
    for path in sorted(entries, key=os.fsencode):
        encoded_path = os.fsencode(path)
        file_digest = entries[path]
        if len(file_digest) != hashlib.sha256().digest_size:
            raise ProvenanceError("selected input SHA-256 must contain 32 raw bytes")
        digest.update(len(encoded_path).to_bytes(8, "big"))
        digest.update(encoded_path)
        digest.update(file_digest)
    return digest.hexdigest()


def required_tool_output(
    command: list[str],
    repository_root: Path,
    tool_runner: ToolRunner,
) -> str:
    result = tool_runner(command, repository_root)
    if result.returncode != 0:
        diagnostic = result.stderr.strip() or "no diagnostic"
        raise ProvenanceError(f"{' '.join(command)} failed: {diagnostic}")
    output = result.stdout.strip()
    if not output or len(output.encode("utf-8")) > 4096:
        raise ProvenanceError(f"{' '.join(command)} returned invalid bounded output")
    return output


def project_configuration_path(project_file_path: Path) -> Path:
    if project_file_path.suffix == ".xcodeproj" or project_file_path.is_dir():
        return project_file_path / "project.xcproj"
    return project_file_path


def read_bounded_regular_file(path: Path, maximum_bytes: int, label: str) -> bytes:
    try:
        before = path.lstat()
    except OSError as error:
        raise ProvenanceError(f"{label} is missing or inaccessible: {error}")
    if not stat.S_ISREG(before.st_mode):
        raise ProvenanceError(f"{label} must be a regular file, not a symlink")
    if before.st_size > maximum_bytes:
        raise ProvenanceError(f"{label} exceeds fixed size bound")

    descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    with os.fdopen(descriptor, "rb") as stream:
        opened = os.fstat(stream.fileno())
        if (opened.st_dev, opened.st_ino) != (before.st_dev, before.st_ino):
            raise ProvenanceError(f"{label} identity changed before reading")
        payload = stream.read(maximum_bytes + 1)
        after_descriptor = os.fstat(stream.fileno())
    if len(payload) > maximum_bytes:
        raise ProvenanceError(f"{label} grew beyond fixed size bound")
    after_path = path.lstat()
    stable_fields = ("st_dev", "st_ino", "st_mode", "st_size", "st_mtime_ns", "st_ctime_ns")
    if any(
        getattr(before, field) != getattr(after_descriptor, field)
        or getattr(before, field) != getattr(after_path, field)
        for field in stable_fields
    ):
        raise ProvenanceError(f"{label} changed while being read")
    return payload


def require_fresh_generated_project(
    arguments: ProvenanceArguments,
    repository_root: Path,
    tool_runner: ToolRunner,
) -> None:
    declared_project = project_configuration_path(arguments.project_file_path)
    if declared_project.name != "project.xcproj":
        raise ProvenanceError("PROJECT_FILE_PATH must name the JSON project.xcproj")
    if (declared_project.parent / "project.pbxproj").exists() or (declared_project.parent / "project.pbxproj").is_symlink():
        raise ProvenanceError("legacy project.pbxproj must not coexist with project.xcproj")
    try:
        project_directory = declared_project.parent.lstat()
    except OSError as error:
        raise ProvenanceError(f"MacScope.xcodeproj is missing or inaccessible: {error}")
    if not stat.S_ISDIR(project_directory.st_mode):
        raise ProvenanceError("MacScope.xcodeproj must be a directory, not a symlink")
    declared_bytes = read_bounded_regular_file(
        declared_project,
        16 * 1024 * 1024,
        "project.xcproj",
    )
    actual_project = declared_project.resolve(strict=True)
    expected_parent = (repository_root / "MacScope" / "MacScope.xcodeproj").resolve(
        strict=True
    )
    if actual_project.parent != expected_parent:
        raise ProvenanceError("PROJECT_FILE_PATH must name MacScope.xcodeproj")
    source_spec_path = arguments.project_yml
    spec_bytes = read_bounded_regular_file(
        source_spec_path,
        MAX_XCODEGEN_SPEC_BYTES,
        "project.yml",
    )
    source_spec = source_spec_path.resolve(strict=True)
    source_root = source_spec.parent
    if source_root != expected_parent.parent:
        raise ProvenanceError("project.yml must belong to the MacScope project root")
    if source_spec.name != "project.yml":
        raise ProvenanceError("XcodeGen validation requires project.yml")
    with tempfile.TemporaryDirectory(prefix="MacScope-Provenance-XcodeGen-") as directory:
        generated_parent = Path(directory)
        generated_parent.chmod(0o700)
        # XcodeGen incorporates the project-root directory name into PBX group
        # identity when project-level configFiles are present. Reproduce the
        # canonical MacScope root name so the byte comparison measures only
        # project.yml and source-tree drift, not a random temporary basename.
        generated_source_root = generated_parent / source_root.name
        generated_source_root.mkdir(mode=0o700)
        generated_project = generated_source_root / "MacScope.xcodeproj"
        for sibling_path in XCODEGEN_REPOSITORY_SIBLING_PATHS:
            declared_sibling_path = f"../{sibling_path}".encode("utf-8")
            if declared_sibling_path not in spec_bytes:
                continue
            sibling_relative = Path(sibling_path)
            if sibling_relative.is_absolute() or ".." in sibling_relative.parts:
                raise ProvenanceError("XcodeGen repository sibling path is unsafe")
            sibling_source = repository_root / sibling_relative
            try:
                sibling_metadata = sibling_source.lstat()
            except OSError as error:
                raise ProvenanceError(
                    f"XcodeGen repository sibling {sibling_path} is missing: {error}"
                )
            if not stat.S_ISDIR(sibling_metadata.st_mode):
                raise ProvenanceError(
                    f"XcodeGen repository sibling {sibling_path} must be an ordinary directory"
                )
            resolved_sibling = sibling_source.resolve(strict=True)
            resolved_repository = repository_root.resolve(strict=True)
            if not resolved_sibling.is_relative_to(resolved_repository):
                raise ProvenanceError("XcodeGen repository sibling escaped repository root")
            generated_sibling = generated_parent / sibling_relative
            generated_sibling.parent.mkdir(parents=True, mode=0o700, exist_ok=True)
            os.symlink(
                resolved_sibling,
                generated_sibling,
                target_is_directory=True,
            )
        source_entries = sorted(source_root.iterdir(), key=lambda entry: entry.name)
        if len(source_entries) > MAX_XCODEGEN_ROOT_ENTRIES:
            raise ProvenanceError("MacScope project root exceeds fixed entry bound")
        for source_entry in source_entries:
            if source_entry.name in {"project.yml", "MacScope.xcodeproj"}:
                continue
            os.symlink(source_entry, generated_source_root / source_entry.name)
        generated_spec = generated_source_root / source_spec.name
        destination_flags = (
            os.O_WRONLY
            | os.O_CREAT
            | os.O_EXCL
            | getattr(os, "O_NOFOLLOW", 0)
        )
        descriptor = os.open(generated_spec, destination_flags, 0o600)
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(spec_bytes)

        command = [governed_xcodegen(repository_root), "generate"]
        result = tool_runner(command, generated_source_root)
        if result.returncode != 0:
            diagnostic = result.stderr.strip() or "no diagnostic"
            raise ProvenanceError(f"fresh XcodeGen validation failed: {diagnostic}")
        conversion = tool_runner(
            ["/usr/bin/xcrun", "xcodebuild", "-convert-project", "Xcode Project",
             "-project", str(generated_project)],
            generated_source_root,
        )
        if conversion.returncode != 0:
            raise ProvenanceError(f"fresh Xcode JSON conversion failed: {conversion.stderr.strip()}")
        if (generated_project / "project.pbxproj").exists():
            raise ProvenanceError("fresh conversion retained the legacy project")
        generated_pbx = generated_project / "project.xcproj"
        try:
            generated_bytes = generated_pbx.read_bytes()
        except OSError as error:
            raise ProvenanceError(f"fresh XcodeGen project is missing: {error}")
        if len(generated_bytes) > 16 * 1024 * 1024:
            raise ProvenanceError("fresh Xcode project exceeds fixed size bound")
        if generated_bytes != declared_bytes:
            raise ProvenanceError("generated JSON project differs from fresh official conversion")


def governed_xcodegen(repository_root: Path) -> str:
    path = Path(os.environ.get("MACSCOPE_XCODEGEN", str(repository_root / "ThirdParty/XcodeGen/bin/xcodegen")))
    if not path.is_absolute():
        raise ProvenanceError("XcodeGen must be an absolute governed tool path")
    return str(path)


def toolchain_evidence(
    arguments: ProvenanceArguments,
    repository_root: Path,
    project_scalars: dict[tuple[str, ...], str],
    tool_runner: ToolRunner,
) -> dict[str, str]:
    xcodegen_output = required_tool_output(
        [governed_xcodegen(repository_root), "version"], repository_root, tool_runner
    )
    xcodegen_match = re.search(r"\b(\d+\.\d+\.\d+)\b", xcodegen_output)
    if xcodegen_match is None:
        raise ProvenanceError("could not parse XcodeGen version")
    xcodegen_version = xcodegen_match.group(1)
    minimum = project_scalars.get(("options", "minimumXcodeGenVersion"))
    if minimum is None or tuple(map(int, xcodegen_version.split("."))) < tuple(
        map(int, minimum.split("."))
    ):
        raise ProvenanceError("active XcodeGen is below the project minimum")
    admitted = _admitted_release(repository_root)
    if admitted is None:
        require_fresh_generated_project(arguments, repository_root, tool_runner)
    elif str(project_configuration_path(arguments.project_file_path)) != admitted["overlay"].get("overlay_project_path"):
        raise ProvenanceError("Release project path differs from admitted operational overlay")

    xcode_output = required_tool_output(
        ["/usr/bin/xcodebuild", "-version"], repository_root, tool_runner
    )
    xcode_match = re.fullmatch(
        r"Xcode (\d+(?:\.\d+){1,2})\nBuild version ([A-Za-z0-9.]+)",
        xcode_output,
    )
    if xcode_match is None or not xcode_match.group(1).startswith("27."):
        raise ProvenanceError("qualification requires the current Xcode 27 major line")

    declared_swift_executable = arguments.swift_executable
    if declared_swift_executable.name != "swiftc":
        raise ProvenanceError("Swift executable must name the Xcode-bundled swiftc")
    developer_dir = arguments.developer_dir.resolve(strict=True)
    swift_executable = declared_swift_executable.resolve(strict=True)
    try:
        swift_executable.relative_to(developer_dir)
    except ValueError:
        raise ProvenanceError("Swift executable must belong to the build-selected DEVELOPER_DIR")
    swift_output = required_tool_output(
        [str(swift_executable), "--version"], repository_root, tool_runner
    )
    swift_version_match = re.search(r"Apple Swift version (\d+(?:\.\d+){1,2})\b", swift_output)
    target_match = re.search(r"(?m)^Target: ([A-Za-z0-9._+\-]+)$", swift_output)
    if (
        swift_version_match is None
        or not swift_version_match.group(1).startswith("6.")
        or target_match is None
        or re.fullmatch(r"arm64-apple-macosx27(?:\.\d+){1,2}", target_match.group(1))
        is None
    ):
        raise ProvenanceError("qualification requires the Xcode 27 Swift 6 arm64 toolchain")

    return {
        "xcodegen_version": xcodegen_version,
        "xcode_version": xcode_match.group(1),
        "xcode_build": xcode_match.group(2),
        "swift_compiler_version": swift_version_match.group(1),
        "swift_target_triple": target_match.group(1),
    }


def third_party_evidence(
    repository_root: Path,
    selected_hashes: dict[str, bytes],
) -> dict[str, object]:
    manifest, _ = load_third_party_manifest(repository_root)
    component_ids = sorted(component["id"] for component in manifest["components"])
    if len(component_ids) != len(set(component_ids)):
        raise ProvenanceError("third-party component ids must be unique")
    distribution = manifest["distribution_policy"]
    required_hashes = (
        "THIRD_PARTY_COMPONENTS.yml",
        "THIRD_PARTY_NOTICES.md",
    )
    if any(path not in selected_hashes for path in required_hashes):
        raise ProvenanceError("third-party governance files are absent from sealed inputs")
    return {
        "third_party_manifest_sha256": selected_hashes[
            "THIRD_PARTY_COMPONENTS.yml"
        ].hex(),
        "third_party_notices_sha256": selected_hashes[
            "THIRD_PARTY_NOTICES.md"
        ].hex(),
        "third_party_component_ids": component_ids,
        "third_party_component_count": len(component_ids),
        "third_party_distribution_status": distribution["status"],
        "third_party_public_distribution_approved": distribution[
            "public_distribution_approved"
        ],
    }


def _provenance_stable_fields(metadata: os.stat_result) -> tuple[int, ...]:
    return (
        metadata.st_dev,
        metadata.st_ino,
        metadata.st_mode,
        metadata.st_nlink,
        metadata.st_size,
        metadata.st_mtime_ns,
        metadata.st_ctime_ns,
    )


def _provenance_shared_directory_binding_fields(
    metadata: os.stat_result,
) -> tuple[int, ...]:
    return (
        metadata.st_dev,
        metadata.st_ino,
        metadata.st_mode,
        metadata.st_uid,
        metadata.st_gid,
    )


def _provenance_directory_flags() -> int:
    return (
        os.O_RDONLY
        | getattr(os, "O_DIRECTORY", 0)
        | getattr(os, "O_NOFOLLOW", 0)
        | getattr(os, "O_CLOEXEC", 0)
    )


def _open_provenance_root(
    path: Path,
    label: str,
) -> tuple[
    tuple[int, ...],
    tuple[tuple[int, str, int, tuple[int, ...]], ...],
    tuple[int, ...],
    tuple[int, ...],
]:
    if not path.is_absolute() or ".." in path.parts:
        raise ProvenanceError(f"{label} must use an absolute canonical path")
    descriptors: list[int] = []
    links: list[tuple[int, str, int, tuple[int, ...]]] = []
    try:
        descriptor = os.open("/", _provenance_directory_flags())
        descriptors.append(descriptor)
        filesystem_root_fields = _provenance_shared_directory_binding_fields(
            os.fstat(descriptor)
        )
        expected = filesystem_root_fields
        for component in path.parts[1:]:
            if not component or component in {".", ".."} or "/" in component:
                raise ProvenanceError(f"{label} has an unsafe ancestry component")
            before = os.stat(component, dir_fd=descriptor, follow_symlinks=False)
            if stat.S_ISLNK(before.st_mode) or not stat.S_ISDIR(before.st_mode):
                raise ProvenanceError(
                    f"{label} ancestry must contain only ordinary directory components"
                )
            child = os.open(
                component,
                _provenance_directory_flags(),
                dir_fd=descriptor,
            )
            descriptors.append(child)
            opened = os.fstat(child)
            after = os.stat(component, dir_fd=descriptor, follow_symlinks=False)
            expected = _provenance_shared_directory_binding_fields(before)
            if (
                _provenance_shared_directory_binding_fields(opened) != expected
                or _provenance_shared_directory_binding_fields(after) != expected
            ):
                raise ProvenanceError(f"{label} ancestry changed during descriptor anchoring")
            links.append((descriptor, component, child, expected))
            descriptor = child
        after_path = path.lstat()
        if _provenance_shared_directory_binding_fields(after_path) != expected:
            raise ProvenanceError(f"{label} changed during descriptor anchoring")
        if (
            _provenance_shared_directory_binding_fields(os.fstat(descriptors[0]))
            != filesystem_root_fields
        ):
            raise ProvenanceError(f"{label} filesystem root changed during anchoring")
        for parent, name, child, fields in links:
            if (
                _provenance_shared_directory_binding_fields(
                    os.stat(name, dir_fd=parent, follow_symlinks=False)
                )
                != fields
                or _provenance_shared_directory_binding_fields(os.fstat(child))
                != fields
            ):
                raise ProvenanceError(f"{label} ancestry changed during anchoring")
    except ProvenanceError:
        for opened_descriptor in reversed(descriptors):
            os.close(opened_descriptor)
        raise
    except OSError as error:
        for opened_descriptor in reversed(descriptors):
            os.close(opened_descriptor)
        raise ProvenanceError(f"{label} cannot be opened safely: {error}") from error
    return tuple(descriptors), tuple(links), expected, filesystem_root_fields


def _open_provenance_directory_at(
    parent_descriptor: int,
    name: str,
    label: str,
) -> tuple[int, tuple[int, ...]]:
    if not name or name in {".", ".."} or "/" in name or any(
        character in name for character in ("\0", "\r", "\n")
    ):
        raise ProvenanceError(f"{label} has an unsafe component")
    descriptor = -1
    try:
        before = os.stat(name, dir_fd=parent_descriptor, follow_symlinks=False)
        if stat.S_ISLNK(before.st_mode) or not stat.S_ISDIR(before.st_mode):
            raise ProvenanceError(f"{label} must be an ordinary directory, not a symlink")
        descriptor = os.open(
            name,
            _provenance_directory_flags(),
            dir_fd=parent_descriptor,
        )
        opened = os.fstat(descriptor)
        after = os.stat(name, dir_fd=parent_descriptor, follow_symlinks=False)
    except OSError as error:
        if descriptor >= 0:
            os.close(descriptor)
        raise ProvenanceError(f"{label} cannot be opened safely: {error}") from error
    expected = _provenance_stable_fields(before)
    if (
        _provenance_stable_fields(opened) != expected
        or _provenance_stable_fields(after) != expected
    ):
        os.close(descriptor)
        raise ProvenanceError(f"{label} changed during descriptor anchoring")
    return descriptor, expected


def _require_exact_directory_entries(
    descriptor: int,
    expected: set[str],
    label: str,
) -> None:
    try:
        observed = set(os.listdir(descriptor))
    except OSError as error:
        raise ProvenanceError(f"{label} cannot be enumerated safely: {error}") from error
    if observed != expected:
        raise ProvenanceError(f"{label} has unexpected entries")


def _read_provenance_file_at(
    parent_descriptor: int,
    name: str,
    maximum_bytes: int,
    label: str,
) -> tuple[bytes, tuple[int, ...]]:
    descriptor = -1
    try:
        before = os.stat(name, dir_fd=parent_descriptor, follow_symlinks=False)
        if (
            stat.S_ISLNK(before.st_mode)
            or not stat.S_ISREG(before.st_mode)
            or before.st_nlink != 1
            or before.st_size > maximum_bytes
        ):
            raise ProvenanceError(f"{label} must be bounded, ordinary, and singly linked")
        descriptor = os.open(
            name,
            os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_CLOEXEC", 0),
            dir_fd=parent_descriptor,
        )
        opened = os.fstat(descriptor)
        payload = bytearray()
        while len(payload) <= maximum_bytes:
            block = os.read(descriptor, min(1024 * 1024, maximum_bytes + 1 - len(payload)))
            if not block:
                break
            payload.extend(block)
        after_descriptor = os.fstat(descriptor)
        after = os.stat(name, dir_fd=parent_descriptor, follow_symlinks=False)
    except OSError as error:
        raise ProvenanceError(f"{label} is missing or inaccessible: {error}") from error
    finally:
        if descriptor >= 0:
            os.close(descriptor)
    expected = _provenance_stable_fields(before)
    if (
        len(payload) > maximum_bytes
        or _provenance_stable_fields(opened) != expected
        or _provenance_stable_fields(after_descriptor) != expected
        or _provenance_stable_fields(after) != expected
    ):
        raise ProvenanceError(f"{label} changed during descriptor-rooted read")
    return bytes(payload), expected


def _digest_provenance_file_at(
    parent_descriptor: int,
    name: str,
    maximum_bytes: int,
    label: str,
    *,
    retain_payload: bool = False,
) -> tuple[str, int, bytes | None, tuple[int, ...]]:
    descriptor = -1
    try:
        before = os.stat(name, dir_fd=parent_descriptor, follow_symlinks=False)
        if (
            stat.S_ISLNK(before.st_mode)
            or not stat.S_ISREG(before.st_mode)
            or before.st_nlink != 1
            or before.st_size > maximum_bytes
        ):
            raise ProvenanceError(f"{label} must be bounded, ordinary, and singly linked")
        descriptor = os.open(
            name,
            os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_CLOEXEC", 0),
            dir_fd=parent_descriptor,
        )
        opened = os.fstat(descriptor)
        digest = hashlib.sha256()
        size = 0
        retained = bytearray() if retain_payload else None
        while True:
            block = os.read(descriptor, 1024 * 1024)
            if not block:
                break
            size += len(block)
            if size > maximum_bytes:
                raise ProvenanceError(f"{label} exceeds its fixed bound")
            digest.update(block)
            if retained is not None:
                retained.extend(block)
        after_descriptor = os.fstat(descriptor)
        after = os.stat(name, dir_fd=parent_descriptor, follow_symlinks=False)
    except OSError as error:
        raise ProvenanceError(f"{label} is missing or inaccessible: {error}") from error
    finally:
        if descriptor >= 0:
            os.close(descriptor)
    expected = _provenance_stable_fields(before)
    if (
        size != before.st_size
        or _provenance_stable_fields(opened) != expected
        or _provenance_stable_fields(after_descriptor) != expected
        or _provenance_stable_fields(after) != expected
    ):
        raise ProvenanceError(f"{label} changed during descriptor-rooted hashing")
    return digest.hexdigest(), size, bytes(retained) if retained is not None else None, expected


def _capture_provenance_tree(
    root_descriptor: int,
    label: str,
) -> tuple[tuple[tuple[str, str, tuple[int, ...], str | None], ...], bytes]:
    records: list[tuple[str, str, tuple[int, ...], str | None]] = []
    manifest_bytes: bytes | None = None
    entry_count = 0
    total_bytes = 0
    path_bytes = 0

    def frame(
        directory_descriptor: int,
        relative: str,
        depth: int,
        *,
        close_on_exit: bool,
        parent_descriptor: int | None = None,
        parent_name: str | None = None,
        opened_fields: tuple[int, ...] | None = None,
    ) -> dict[str, object]:
        nonlocal entry_count, path_bytes
        if depth > MAX_PROVENANCE_TREE_DEPTH:
            raise ProvenanceError(f"{label} exceeds its fixed traversal depth")
        remaining_entries = MAX_PROVENANCE_TREE_ENTRIES - entry_count
        names: list[str] = []
        try:
            with os.scandir(directory_descriptor) as iterator:
                for entry in iterator:
                    if len(names) >= remaining_entries:
                        raise ProvenanceError(f"{label} exceeds its fixed entry bound")
                    names.append(entry.name)
        except OSError as error:
            raise ProvenanceError(f"{label} cannot be enumerated safely: {error}") from error
        names.sort(key=os.fsencode)
        retained_paths = 0
        for name in names:
            if not name or name in {".", ".."} or "/" in name or any(
                character in name for character in ("\0", "\r", "\n")
            ):
                raise ProvenanceError(f"{label} contains an unsafe path")
            child_relative = f"{relative}/{name}" if relative else name
            retained_paths += len(os.fsencode(child_relative))
        if path_bytes + retained_paths > MAX_PROVENANCE_TREE_PATH_BYTES:
            raise ProvenanceError(f"{label} exceeds its fixed path-memory bound")
        entry_count += len(names)
        path_bytes += retained_paths
        return {
            "descriptor": directory_descriptor,
            "relative": relative,
            "depth": depth,
            "close_on_exit": close_on_exit,
            "parent_descriptor": parent_descriptor,
            "parent_name": parent_name,
            "opened_fields": opened_fields,
            "root_before": _provenance_stable_fields(os.fstat(directory_descriptor)),
            "names": names,
            "index": 0,
        }

    stack = [frame(root_descriptor, "", 0, close_on_exit=False)]
    try:
        while stack:
            current = stack[-1]
            directory_descriptor = current["descriptor"]
            names = current["names"]
            index = current["index"]
            assert isinstance(directory_descriptor, int)
            assert isinstance(names, list)
            assert isinstance(index, int)
            if index >= len(names):
                if (
                    _provenance_stable_fields(os.fstat(directory_descriptor))
                    != current["root_before"]
                ):
                    raise ProvenanceError(f"{label} directory changed during snapshot")
                stack.pop()
                if current["close_on_exit"]:
                    relative = current["relative"]
                    parent_descriptor = current["parent_descriptor"]
                    parent_name = current["parent_name"]
                    opened_fields = current["opened_fields"]
                    assert isinstance(relative, str)
                    assert isinstance(parent_descriptor, int)
                    assert isinstance(parent_name, str)
                    assert isinstance(opened_fields, tuple)
                    after_descriptor = _provenance_stable_fields(
                        os.fstat(directory_descriptor)
                    )
                    os.close(directory_descriptor)
                    current["close_on_exit"] = False
                    after = _provenance_stable_fields(
                        os.stat(
                            parent_name,
                            dir_fd=parent_descriptor,
                            follow_symlinks=False,
                        )
                    )
                    if after_descriptor != opened_fields or after != opened_fields:
                        raise ProvenanceError(f"{label} directory changed during snapshot")
                    records.append((relative, "directory", opened_fields, None))
                continue

            name = names[index]
            current["index"] = index + 1
            assert isinstance(name, str)
            relative = current["relative"]
            depth = current["depth"]
            assert isinstance(relative, str)
            assert isinstance(depth, int)
            child_relative = f"{relative}/{name}" if relative else name
            before = os.stat(name, dir_fd=directory_descriptor, follow_symlinks=False)
            expected = _provenance_stable_fields(before)
            if stat.S_ISLNK(before.st_mode):
                raise ProvenanceError(f"{label} contains a symbolic link")
            if stat.S_ISDIR(before.st_mode):
                child_descriptor, opened_fields = _open_provenance_directory_at(
                    directory_descriptor, name, f"{label} directory"
                )
                try:
                    child_frame = frame(
                        child_descriptor,
                        child_relative,
                        depth + 1,
                        close_on_exit=True,
                        parent_descriptor=directory_descriptor,
                        parent_name=name,
                        opened_fields=opened_fields,
                    )
                except BaseException:
                    os.close(child_descriptor)
                    raise
                if opened_fields != expected:
                    os.close(child_descriptor)
                    raise ProvenanceError(f"{label} directory changed during snapshot")
                stack.append(child_frame)
                continue
            if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1:
                raise ProvenanceError(f"{label} files must be ordinary and singly linked")
            digest, size, payload, opened_fields = _digest_provenance_file_at(
                directory_descriptor,
                name,
                (
                    MAX_NATIVE_MATERIALIZATION_MANIFEST_BYTES
                    if child_relative == "MATERIALIZATION.json"
                    else MAX_SINGLE_INPUT_BYTES
                ),
                f"{label} file",
                retain_payload=child_relative == "MATERIALIZATION.json",
            )
            if opened_fields != expected:
                raise ProvenanceError(f"{label} file changed during snapshot")
            total_bytes += size
            if total_bytes > MAX_TOTAL_INPUT_BYTES:
                raise ProvenanceError(f"{label} exceeds its fixed byte bound")
            if child_relative == "MATERIALIZATION.json":
                assert payload is not None
                manifest_bytes = payload
            records.append((child_relative, "file", expected, digest))
    finally:
        for pending in reversed(stack):
            if pending["close_on_exit"]:
                descriptor = pending["descriptor"]
                assert isinstance(descriptor, int)
                os.close(descriptor)
                pending["close_on_exit"] = False
    if manifest_bytes is None:
        raise ProvenanceError(f"{label} lacks MATERIALIZATION.json")
    return tuple(records), manifest_bytes


def _canonical_release_output_ancestry(app_root: Path, output_parent: Path) -> Path:
    try:
        canonical_app_root = app_root.resolve(strict=True)
        canonical_output_parent = output_parent.resolve(strict=True)
    except OSError as error:
        raise ProvenanceError(
            f"Release provenance app output ancestry is missing or inaccessible: {error}"
        ) from error
    if canonical_app_root == app_root and canonical_output_parent == output_parent:
        return canonical_app_root

    # Xcode may spell build products through Darwin's two fixed, root-owned
    # compatibility aliases. Accept only these operating-system aliases, and
    # only when every component below the alias is already canonical. Arbitrary
    # or nested symlinked build ancestry remains fail-closed.
    darwin_system_aliases = (
        (Path("/tmp"), Path("/private/tmp"), {"private/tmp", "/private/tmp"}),
        (Path("/var"), Path("/private/var"), {"private/var", "/private/var"}),
    )
    for alias, canonical_root, accepted_targets in darwin_system_aliases:
        try:
            app_relative = app_root.relative_to(alias)
            output_relative = output_parent.relative_to(alias)
            alias_metadata = alias.lstat()
            alias_target = os.readlink(alias)
            resolved_alias = alias.resolve(strict=True)
        except (OSError, ValueError):
            continue
        if (
            sys.platform == "darwin"
            and stat.S_ISLNK(alias_metadata.st_mode)
            and alias_metadata.st_uid == 0
            and alias_target in accepted_targets
            and resolved_alias == canonical_root
            and canonical_app_root == canonical_root / app_relative
            and canonical_output_parent == canonical_root / output_relative
        ):
            return canonical_app_root

    raise ProvenanceError(
        "Release provenance app output ancestry must be canonical and symlink-free"
    )


def _derived_embedded_native_decompiler_paths(
    arguments: ProvenanceArguments,
) -> tuple[Path, Path]:
    output = arguments.output
    expected_output_suffix = Path(
        "MacScope.app/Contents/Resources/MacScopeBuildProvenance.json"
    )
    if (
        not output.is_absolute()
        or ".." in output.parts
        or tuple(output.parts[-len(expected_output_suffix.parts):])
        != expected_output_suffix.parts
    ):
        raise ProvenanceError(
            "Release provenance output must be MacScope.app/Contents/Resources/"
            "MacScopeBuildProvenance.json"
        )
    lexical_app_root = output.parents[2]
    canonical_app_root = _canonical_release_output_ancestry(
        lexical_app_root,
        output.parent,
    )
    lexical_golden = (
        lexical_app_root
        / "Contents/XPCServices/NativeDecompilerXPCService.xpc/Contents/Resources/"
        "NativeDecompilerBridgeGolden.json"
    )
    requested = arguments.native_decompiler_golden_result
    if requested is None or ".." in requested.parts or requested != lexical_golden:
        raise ProvenanceError(
            "Release provenance requires the embedded XPC native decompiler golden result "
            "at the exact path derived from the app output"
        )
    canonical_golden = (
        canonical_app_root
        / "Contents/XPCServices/NativeDecompilerXPCService.xpc/Contents/Resources/"
        "NativeDecompilerBridgeGolden.json"
    )
    return canonical_app_root, canonical_golden


def _capture_embedded_native_decompiler_snapshot(
    app_root: Path,
    *,
    retain_descriptors: bool = False,
) -> dict[str, object]:
    descriptors: list[int] = []
    directory_descriptors: list[tuple[int, bool]] = []
    ancestry_link_records: list[tuple[int, str, int, tuple[int, ...]]] = []
    link_records: list[tuple[int, str, int, tuple[int, ...]]] = []
    filesystem_root_binding: tuple[int, tuple[int, ...]] | None = None

    def open_root(path: Path, label: str) -> tuple[int, tuple[int, ...]]:
        nonlocal filesystem_root_binding
        chain, links, fields, root_fields = _open_provenance_root(path, label)
        descriptors.extend(chain)
        ancestry_link_records.extend(links)
        descriptor = chain[-1]
        directory_descriptors.append((descriptor, True))
        filesystem_root_binding = (chain[0], root_fields)
        return descriptor, fields

    def open_at(parent: int, name: str, label: str) -> tuple[int, tuple[int, ...]]:
        descriptor, fields = _open_provenance_directory_at(parent, name, label)
        descriptors.append(descriptor)
        directory_descriptors.append((descriptor, False))
        link_records.append((parent, name, descriptor, fields))
        return descriptor, fields

    directory_records: list[tuple[str, tuple[int, ...]]] = []
    try:
        app_parent, parent_fields = open_root(
            app_root.parent,
            "MacScope application bundle parent",
        )
        directory_records.append(("app-parent", parent_fields))
        app, fields = open_at(app_parent, app_root.name, "MacScope application bundle")
        directory_records.append(("MacScope.app", fields))
        contents, fields = open_at(app, "Contents", "application Contents")
        directory_records.append(("Contents", fields))
        _application_resources, fields = open_at(
            contents,
            "Resources",
            "application Resources",
        )
        directory_records.append(("Contents/Resources", fields))
        xpc_services, fields = open_at(contents, "XPCServices", "application XPCServices")
        directory_records.append(("Contents/XPCServices", fields))
        service, fields = open_at(
            xpc_services,
            "NativeDecompilerXPCService.xpc",
            "embedded native decompiler service",
        )
        directory_records.append(("service", fields))
        _require_exact_directory_entries(service, {"Contents"}, "embedded service root")
        service_contents, fields = open_at(service, "Contents", "service Contents")
        directory_records.append(("service/Contents", fields))
        _require_exact_directory_entries(
            service_contents,
            {"Info.plist", "MacOS", "Resources", "_CodeSignature"},
            "embedded service Contents",
        )
        resources, fields = open_at(service_contents, "Resources", "service Resources")
        directory_records.append(("service/Contents/Resources", fields))
        _require_exact_directory_entries(
            resources,
            {"NativeDecompilerBridgeGolden.json", "NativeDecompilerPackage"},
            "embedded service Resources",
        )
        golden_bytes, golden_fields = _read_provenance_file_at(
            resources,
            "NativeDecompilerBridgeGolden.json",
            64 * 1024,
            "embedded native decompiler golden result",
        )
        materialization, fields = open_at(
            resources,
            "NativeDecompilerPackage",
            "embedded native decompiler package",
        )
        directory_records.append(("service/Contents/Resources/NativeDecompilerPackage", fields))
        package_records, manifest_bytes = _capture_provenance_tree(
            materialization,
            "embedded native decompiler package",
        )
        info_bytes, info_fields = _read_provenance_file_at(
            service_contents, "Info.plist", 1024 * 1024, "service Info.plist"
        )
        macos, fields = open_at(service_contents, "MacOS", "service MacOS")
        directory_records.append(("service/Contents/MacOS", fields))
        _require_exact_directory_entries(
            macos,
            {"NativeDecompilerXPCService"},
            "embedded service MacOS",
        )
        executable_digest, executable_size, _payload, executable_fields = (
            _digest_provenance_file_at(
            macos,
            "NativeDecompilerXPCService",
            256 * 1024 * 1024,
            "service executable",
            )
        )
        signature, fields = open_at(
            service_contents, "_CodeSignature", "service code-signature directory"
        )
        directory_records.append(("service/Contents/_CodeSignature", fields))
        _require_exact_directory_entries(
            signature,
            {"CodeResources"},
            "embedded service code-signature directory",
        )
        code_resources_digest, code_resources_size, _payload, code_resources_fields = (
            _digest_provenance_file_at(
            signature,
            "CodeResources",
            16 * 1024 * 1024,
            "service CodeResources",
            )
        )
        for (descriptor, is_shared_ancestor), (_name, expected) in zip(
            directory_descriptors,
            directory_records,
        ):
            observed = (
                _provenance_shared_directory_binding_fields(os.fstat(descriptor))
                if is_shared_ancestor
                else _provenance_stable_fields(os.fstat(descriptor))
            )
            if observed != expected:
                raise ProvenanceError("embedded native decompiler snapshot changed during capture")
        assert filesystem_root_binding is not None
        if (
            _provenance_shared_directory_binding_fields(
                os.fstat(filesystem_root_binding[0])
            )
            != filesystem_root_binding[1]
        ):
            raise ProvenanceError("filesystem root changed during embedded snapshot")
        if (
            _provenance_shared_directory_binding_fields(app_root.parent.lstat())
            != parent_fields
        ):
            raise ProvenanceError("application bundle parent changed during snapshot")
        for parent, name, child, expected in ancestry_link_records:
            if (
                _provenance_shared_directory_binding_fields(
                    os.stat(name, dir_fd=parent, follow_symlinks=False)
                )
                != expected
                or _provenance_shared_directory_binding_fields(os.fstat(child))
                != expected
            ):
                raise ProvenanceError(
                    "embedded native decompiler ancestry changed during snapshot"
                )
        for parent, name, child, expected in link_records:
            if (
                _provenance_stable_fields(
                    os.stat(name, dir_fd=parent, follow_symlinks=False)
                )
                != expected
                or _provenance_stable_fields(os.fstat(child)) != expected
            ):
                raise ProvenanceError(
                    "embedded native decompiler path graph changed during snapshot"
                )
        _require_exact_directory_entries(service, {"Contents"}, "embedded service root")
        _require_exact_directory_entries(
            service_contents,
            {"Info.plist", "MacOS", "Resources", "_CodeSignature"},
            "embedded service Contents",
        )
        _require_exact_directory_entries(
            resources,
            {"NativeDecompilerBridgeGolden.json", "NativeDecompilerPackage"},
            "embedded service Resources",
        )
        _require_exact_directory_entries(
            macos, {"NativeDecompilerXPCService"}, "embedded service MacOS"
        )
        _require_exact_directory_entries(
            signature,
            {"CodeResources"},
            "embedded service code-signature directory",
        )
        snapshot = {
            "directories": tuple(directory_records),
            "golden_bytes": golden_bytes,
            "golden_fields": golden_fields,
            "package_records": package_records,
            "manifest_bytes": manifest_bytes,
            "info_bytes": info_bytes,
            "info_fields": info_fields,
            "executable_digest": executable_digest,
            "executable_size": executable_size,
            "executable_fields": executable_fields,
            "code_resources_digest": code_resources_digest,
            "code_resources_size": code_resources_size,
            "code_resources_fields": code_resources_fields,
        }
        if retain_descriptors:
            snapshot["_lease_descriptors"] = tuple(descriptors)
            snapshot["_lease_ancestry_links"] = tuple(ancestry_link_records)
            snapshot["_lease_links"] = tuple(link_records)
            snapshot["_lease_filesystem_root"] = filesystem_root_binding
            snapshot["_lease_root"] = (app_root.parent, parent_fields)
            snapshot["_lease_output_resources_descriptor"] = _application_resources
            snapshot["_lease_materialization_descriptor"] = materialization
            snapshot["_lease_file_links"] = (
                (resources, "NativeDecompilerBridgeGolden.json", golden_fields),
                (service_contents, "Info.plist", info_fields),
                (macos, "NativeDecompilerXPCService", executable_fields),
                (signature, "CodeResources", code_resources_fields),
            )
            descriptors = []
        return snapshot
    finally:
        for descriptor in reversed(descriptors):
            os.close(descriptor)


def _public_embedded_snapshot(snapshot: dict[str, object]) -> dict[str, object]:
    return {key: value for key, value in snapshot.items() if not key.startswith("_lease_")}


def _close_embedded_snapshot_lease(snapshot: dict[str, object]) -> None:
    descriptors = snapshot.get("_lease_descriptors", ())
    assert isinstance(descriptors, tuple)
    for descriptor in reversed(descriptors):
        os.close(descriptor)


def _revalidate_embedded_snapshot_lease(
    app_root: Path,
    snapshot: dict[str, object],
) -> None:
    expected_public = _public_embedded_snapshot(snapshot)
    if _capture_embedded_native_decompiler_snapshot(app_root) != expected_public:
        raise ProvenanceError(
            "embedded native decompiler package or service changed before publication"
        )
    materialization_descriptor = snapshot["_lease_materialization_descriptor"]
    assert isinstance(materialization_descriptor, int)
    package_records, manifest_bytes = _capture_provenance_tree(
        materialization_descriptor,
        "embedded native decompiler package",
    )
    if (
        package_records != snapshot["package_records"]
        or manifest_bytes != snapshot["manifest_bytes"]
    ):
        raise ProvenanceError("embedded native decompiler package changed before publication")
    filesystem_root_descriptor, filesystem_root_fields = snapshot[
        "_lease_filesystem_root"
    ]
    assert isinstance(filesystem_root_descriptor, int)
    if (
        _provenance_shared_directory_binding_fields(
            os.fstat(filesystem_root_descriptor)
        )
        != filesystem_root_fields
    ):
        raise ProvenanceError("filesystem root changed before publication")
    root_path, root_fields = snapshot["_lease_root"]
    assert isinstance(root_path, Path)
    if _provenance_shared_directory_binding_fields(root_path.lstat()) != root_fields:
        raise ProvenanceError("application bundle parent changed before publication")
    file_links = snapshot["_lease_file_links"]
    assert isinstance(file_links, tuple)
    for parent, name, expected in file_links:
        if _provenance_stable_fields(
            os.stat(name, dir_fd=parent, follow_symlinks=False)
        ) != expected:
            raise ProvenanceError(
                "embedded native decompiler file changed before publication"
            )
    ancestry_links = snapshot["_lease_ancestry_links"]
    assert isinstance(ancestry_links, tuple)
    for parent, name, child, expected in ancestry_links:
        if (
            _provenance_shared_directory_binding_fields(
                os.stat(name, dir_fd=parent, follow_symlinks=False)
            )
            != expected
            or _provenance_shared_directory_binding_fields(os.fstat(child))
            != expected
        ):
            raise ProvenanceError(
                "embedded native decompiler ancestry changed before publication"
            )
    links = snapshot["_lease_links"]
    assert isinstance(links, tuple)
    for parent, name, child, expected in links:
        if (
            _provenance_stable_fields(
                os.stat(name, dir_fd=parent, follow_symlinks=False)
            )
            != expected
            or _provenance_stable_fields(os.fstat(child)) != expected
        ):
            raise ProvenanceError(
                "embedded native decompiler path graph changed before publication"
            )


def _refresh_output_resources_binding(snapshot: dict[str, object]) -> None:
    output_descriptor = snapshot["_lease_output_resources_descriptor"]
    assert isinstance(output_descriptor, int)
    current = _provenance_stable_fields(os.fstat(output_descriptor))
    directories = list(snapshot["directories"])
    for index, (name, _expected) in enumerate(directories):
        if name == "Contents/Resources":
            directories[index] = (name, current)
            break
    else:
        raise ProvenanceError("application Resources binding is missing")
    snapshot["directories"] = tuple(directories)
    links = list(snapshot["_lease_links"])
    for index, (parent, name, child, _expected) in enumerate(links):
        if child == output_descriptor:
            observed = _provenance_stable_fields(
                os.stat(name, dir_fd=parent, follow_symlinks=False)
            )
            if observed != current:
                raise ProvenanceError("application Resources changed before publication")
            links[index] = (parent, name, child, current)
            break
    else:
        raise ProvenanceError("application Resources path binding is missing")
    snapshot["_lease_links"] = tuple(links)


def _write_release_provenance_at_snapshot_boundary(
    arguments: ProvenanceArguments,
    payload: bytes,
    expected_evidence: dict[str, object],
) -> None:
    admitted = _admitted_release(arguments.repository_root.resolve(strict=True))
    if admitted is not None and admitted.get("current_release"):
        _release_admission.publish(arguments.output, payload, admitted["lease"],
                                   lambda: _release_admission.revalidate(admitted))
        return
    app_root, golden_path = _derived_embedded_native_decompiler_paths(arguments)
    snapshot = _capture_embedded_native_decompiler_snapshot(
        app_root,
        retain_descriptors=True,
    )
    output_descriptor = snapshot["_lease_output_resources_descriptor"]
    assert isinstance(output_descriptor, int)
    temporary_name = f".{arguments.output.name}.{secrets.token_hex(12)}"
    temporary_descriptor = -1
    ghostty_surface_snapshot: dict[str, object] | None = None
    try:
        verified_sleigh = verified_sleigh_materialization(
            arguments,
            materialization_root=(
                None
                if arguments.configuration == "Release"
                else golden_path.parent / "NativeDecompilerPackage"
            ),
        )
        golden_bytes = snapshot["golden_bytes"]
        assert isinstance(golden_bytes, bytes)
        try:
            golden = json.loads(golden_bytes)
        except (UnicodeDecodeError, json.JSONDecodeError) as error:
            raise ProvenanceError("embedded native decompiler golden result is malformed") from error
        observed_evidence = {
            "native_decompiler_golden_result_sha256": hashlib.sha256(golden_bytes).hexdigest(),
            "native_decompiler_golden_result": golden,
            **_embedded_package_evidence_from_snapshot(
                snapshot,
                golden,
                verified_sleigh,
            ),
            **_embedded_service_evidence_from_snapshot(snapshot),
        }
        if arguments.configuration == "Release":
            observed_evidence.update(
                sleigh_materialization_evidence(arguments, verified_sleigh)
            )
            ghostty_evidence, ghostty_surface_snapshot = (
                _capture_ghostty_surface_evidence(
                    arguments,
                    retain_descriptors=True,
                )
            )
            observed_evidence.update(ghostty_evidence)
        for key, observed in observed_evidence.items():
            if expected_evidence.get(key) != observed:
                raise ProvenanceError(
                    "embedded native decompiler evidence changed before publication"
                )
        temporary_descriptor = os.open(
            temporary_name,
            os.O_WRONLY
            | os.O_CREAT
            | os.O_EXCL
            | getattr(os, "O_NOFOLLOW", 0)
            | getattr(os, "O_CLOEXEC", 0),
            0o600,
            dir_fd=output_descriptor,
        )
        offset = 0
        while offset < len(payload):
            offset += os.write(temporary_descriptor, payload[offset:])
        os.fsync(temporary_descriptor)
        os.fchmod(temporary_descriptor, 0o644)
        _refresh_output_resources_binding(snapshot)
        _revalidate_embedded_snapshot_lease(app_root, snapshot)
        os.replace(
            temporary_name,
            arguments.output.name,
            src_dir_fd=output_descriptor,
            dst_dir_fd=output_descriptor,
        )
        temporary_name = ""
        _refresh_output_resources_binding(snapshot)
        _revalidate_embedded_snapshot_lease(app_root, snapshot)
        published, _fields = _read_provenance_file_at(
            output_descriptor,
            arguments.output.name,
            MAX_OUTPUT_BYTES,
            "published Release provenance",
        )
        if published != payload:
            raise ProvenanceError("published Release provenance differs from prepared payload")
        _revalidate_embedded_snapshot_lease(app_root, snapshot)
        if ghostty_surface_snapshot is not None:
            _revalidate_ghostty_surface_snapshot(ghostty_surface_snapshot)
    except OSError as error:
        raise ProvenanceError(f"Release provenance cannot be published safely: {error}") from error
    finally:
        if temporary_descriptor >= 0:
            os.close(temporary_descriptor)
        # Darwin cannot condition unlink on the retained inode. After any failure,
        # preserve the temporary name or a substituted replacement rather than
        # re-resolving mutable state and possibly deleting an unowned object.
        _close_ghostty_surface_snapshot(ghostty_surface_snapshot)
        _close_embedded_snapshot_lease(snapshot)


def _load_strict_sleigh_materialization_verifier(
    repository_root: Path,
) -> Callable[[Path], dict[str, Any]]:
    helper = (
        repository_root
        / "Scripts"
        / "native-decompiler-direct"
        / "sleigh_package.py"
    )
    try:
        metadata = helper.lstat()
    except OSError as error:
        raise ProvenanceError("strict SLEIGH materialization verifier is unavailable") from error
    if (
        stat.S_ISLNK(metadata.st_mode)
        or not stat.S_ISREG(metadata.st_mode)
        or metadata.st_nlink != 1
    ):
        raise ProvenanceError(
            "strict SLEIGH materialization verifier must be an ordinary singly linked file"
        )
    specification = importlib.util.spec_from_file_location(
        "macscope_release_sleigh_materialization_verifier",
        helper,
    )
    if specification is None or specification.loader is None:
        raise ProvenanceError("could not load strict SLEIGH materialization verifier")
    module = importlib.util.module_from_spec(specification)
    previous_dont_write_bytecode = sys.dont_write_bytecode
    try:
        sys.dont_write_bytecode = True
        sys.modules[specification.name] = module
        specification.loader.exec_module(module)
    except Exception as error:
        sys.modules.pop(specification.name, None)
        raise ProvenanceError("could not load strict SLEIGH materialization verifier") from error
    finally:
        sys.dont_write_bytecode = previous_dont_write_bytecode
    verifier = getattr(module, "verify_materialization", None)
    if not callable(verifier):
        raise ProvenanceError("strict SLEIGH materialization verifier has no callable entrypoint")
    return verifier


def verified_sleigh_materialization(
    arguments: ProvenanceArguments,
    *,
    materialization_root: Path | None = None,
) -> dict[str, Any]:
    root = (
        materialization_root
        if materialization_root is not None
        else arguments.sleigh_materialization_root
    )
    if root is None:
        raise ProvenanceError("SLEIGH materialization root is unavailable")
    admitted = _admitted_release(arguments.repository_root.resolve(strict=True))
    if admitted is not None and arguments.configuration == "Release":
        if str(root.resolve(strict=True)) != admitted["receipt"].get("sleigh_materialization_root"):
            raise ProvenanceError("SLEIGH root differs from admitted qualification")
        value = _receipt_json(root.resolve(strict=True) / "MATERIALIZATION.json", "admitted SLEIGH manifest")
        if value.get("componentId") != "sleigh-native-source-dcp03b4" or value.get("schemaVersion") != 2:
            raise ProvenanceError("admitted SLEIGH identity is unsupported")
        return value
    verifier = arguments.sleigh_materialization_verifier
    if verifier is None:
        verifier = _load_strict_sleigh_materialization_verifier(
            arguments.repository_root.resolve(strict=True)
        )
    try:
        value = verifier(root.resolve(strict=True))
    except Exception as error:
        raise ProvenanceError(
            f"strict SLEIGH materialization verification failed: {error}"
        ) from error
    if not isinstance(value, dict):
        raise ProvenanceError("strict SLEIGH materialization verifier returned no identity")
    schema_version = value.get("schemaVersion")
    expected_component = {
        1: "sleigh-native-dcp03b4",
        2: "sleigh-native-source-dcp03b4",
    }.get(schema_version)
    if expected_component is None or value.get("componentId") != expected_component:
        raise ProvenanceError("strict SLEIGH materialization identity is unsupported")
    package = value.get("package")
    if (
        not isinstance(package, dict)
        or package.get("relativeRoot") != "package"
        or not isinstance(package.get("treeSha256"), str)
        or HEX_SHA256.fullmatch(package["treeSha256"]) is None
    ):
        raise ProvenanceError("strict SLEIGH materialization package identity is malformed")
    manifest_path = root.resolve(strict=True) / "MATERIALIZATION.json"
    manifest_bytes = read_bounded_regular_file(
        manifest_path,
        MAX_NATIVE_MATERIALIZATION_MANIFEST_BYTES,
        "strict SLEIGH materialization manifest",
    )
    if manifest_bytes != canonical_json(value):
        raise ProvenanceError(
            "strict SLEIGH materialization identity differs from its canonical manifest"
        )
    return value


def sleigh_materialization_evidence(
    arguments: ProvenanceArguments,
    materialization: dict[str, Any],
) -> dict[str, object]:
    root = arguments.sleigh_materialization_root
    assert root is not None
    manifest_bytes = read_bounded_regular_file(
        root.resolve(strict=True) / "MATERIALIZATION.json",
        MAX_NATIVE_MATERIALIZATION_MANIFEST_BYTES,
        "strict SLEIGH materialization manifest",
    )
    package = materialization["package"]
    assert isinstance(package, dict)
    return {
        "sleigh_materialization_schema_version": materialization["schemaVersion"],
        "sleigh_materialization_component_id": materialization["componentId"],
        "sleigh_materialization_manifest_sha256": (
            _admitted_release(arguments.repository_root.resolve(strict=True))["receipt"]["sleigh_materialization_manifest_sha256"]
            if _admitted_release(arguments.repository_root.resolve(strict=True)) is not None
            else hashlib.sha256(manifest_bytes).hexdigest()
        ),
        "sleigh_materialization_tree_sha256": package["treeSha256"],
    }


def _ghostty_surface_manifest(
    path: Path,
) -> tuple[dict[str, str], bytes]:
    payload = read_bounded_regular_file(
        path,
        64 * 1024,
        "Ghostty surface schema-3 source manifest",
    )
    try:
        text = payload.decode("utf-8", errors="strict")
    except UnicodeDecodeError as error:
        raise ProvenanceError("Ghostty surface source manifest must be UTF-8") from error
    if not text.endswith("\n") or "\r" in text or "\0" in text:
        raise ProvenanceError("Ghostty surface source manifest is not canonical text")
    lines = text[:-1].split("\n")
    keys: list[str] = []
    values: dict[str, str] = {}
    for line in lines:
        if line.count("=") != 1:
            raise ProvenanceError("Ghostty surface source manifest is malformed")
        key, value = line.split("=", 1)
        if not key or not value or key in values:
            raise ProvenanceError("Ghostty surface source manifest is malformed")
        keys.append(key)
        values[key] = value
    if tuple(keys) != GHOSTTY_SURFACE_MANIFEST_KEYS:
        raise ProvenanceError(
            "Ghostty surface source manifest has missing, reordered, or unknown fields"
        )
    for key, expected in EXPECTED_GHOSTTY_SURFACE_MANIFEST_FIELDS.items():
        if values[key] != expected:
            raise ProvenanceError(
                f"Ghostty surface source manifest has unexpected {key}"
            )
    for key in (
        "info_plist_sha256",
        "archive_sha256",
        "header_sha256",
        "module_map_sha256",
    ):
        if HEX_SHA256.fullmatch(values[key]) is None:
            raise ProvenanceError(
                f"Ghostty surface source manifest has malformed {key}"
            )
    return values, payload


class DuplicateGhosttySurfaceDescriptorKey(ValueError):
    pass


def _ghostty_surface_descriptor_object(
    pairs: list[tuple[str, Any]],
) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise DuplicateGhosttySurfaceDescriptorKey(key)
        result[key] = value
    return result


def _validate_ghostty_surface_staged_descriptor(
    payload: bytes,
    *,
    source_manifest_sha256: str,
    observed: dict[str, tuple[str, int, str]],
) -> None:
    try:
        descriptor = json.loads(
            payload,
            object_pairs_hook=_ghostty_surface_descriptor_object,
            parse_constant=lambda value: (_ for _ in ()).throw(ValueError(value)),
        )
    except DuplicateGhosttySurfaceDescriptorKey as error:
        raise ProvenanceError(
            f"Ghostty surface staged descriptor contains duplicate key: {error.args[0]}"
        ) from error
    except (UnicodeDecodeError, json.JSONDecodeError, ValueError) as error:
        raise ProvenanceError("Ghostty surface staged descriptor is malformed JSON") from error

    if not isinstance(descriptor, dict) or set(descriptor) != {
        "leaves",
        "schema_version",
        "source_manifest_sha256",
    }:
        raise ProvenanceError("Ghostty surface staged descriptor schema is not closed")
    if type(descriptor["schema_version"]) is not int or descriptor["schema_version"] != 1:
        raise ProvenanceError("Ghostty surface staged descriptor schema version is unsupported")
    if descriptor["source_manifest_sha256"] != source_manifest_sha256:
        raise ProvenanceError(
            "Ghostty surface staged descriptor does not bind the source manifest"
        )
    expected_leaves = [
        {
            "role": role,
            "relative_path": relative_path,
            "sha256": observed[relative_path][2],
        }
        for role, relative_path, _ in GHOSTTY_SURFACE_STAGED_LEAVES
    ]
    if descriptor["leaves"] != expected_leaves:
        raise ProvenanceError(
            "Ghostty surface staged descriptor does not bind the exact leaf roles, paths, and hashes"
        )
    if payload != canonical_json(descriptor):
        raise ProvenanceError("Ghostty surface staged descriptor is not canonical JSON")


def _revalidate_ghostty_surface_snapshot_unchecked(snapshot: dict[str, object]) -> None:
    root_descriptor = snapshot["root_descriptor"]
    headers_descriptor = snapshot["headers_descriptor"]
    assert isinstance(root_descriptor, int)
    assert isinstance(headers_descriptor, int)
    _require_exact_directory_entries(
        root_descriptor,
        {GHOSTTY_SURFACE_STAGED_DESCRIPTOR, "Headers", "libghostty-internal.a"},
        "Ghostty surface staged root",
    )
    _require_exact_directory_entries(
        headers_descriptor,
        {"ghostty.h", "module.modulemap"},
        "Ghostty surface staged Headers",
    )
    if _provenance_stable_fields(os.fstat(root_descriptor)) != snapshot["root_fields"]:
        raise ProvenanceError("Ghostty surface staged root changed during verification")
    if (
        _provenance_stable_fields(os.fstat(headers_descriptor))
        != snapshot["headers_fields"]
    ):
        raise ProvenanceError("Ghostty surface staged Headers changed during verification")
    filesystem_root_descriptor, filesystem_root_fields = snapshot["filesystem_root"]
    assert isinstance(filesystem_root_descriptor, int)
    if (
        _provenance_shared_directory_binding_fields(
            os.fstat(filesystem_root_descriptor)
        )
        != filesystem_root_fields
    ):
        raise ProvenanceError("filesystem root changed during Ghostty surface verification")
    for parent, name, child, expected in snapshot["ancestry_links"]:
        if (
            _provenance_shared_directory_binding_fields(
                os.stat(name, dir_fd=parent, follow_symlinks=False)
            )
            != expected
            or _provenance_shared_directory_binding_fields(os.fstat(child))
            != expected
        ):
            raise ProvenanceError(
                "Ghostty surface staged ancestry changed during verification"
            )
    header_parent, header_name, header_child, header_expected = snapshot[
        "headers_link"
    ]
    if (
        _provenance_stable_fields(
            os.stat(header_name, dir_fd=header_parent, follow_symlinks=False)
        )
        != header_expected
        or _provenance_stable_fields(os.fstat(header_child)) != header_expected
    ):
        raise ProvenanceError("Ghostty surface Headers path changed during verification")
    for parent, name, expected in snapshot["file_links"]:
        if (
            _provenance_stable_fields(
                os.stat(name, dir_fd=parent, follow_symlinks=False)
            )
            != expected
        ):
            raise ProvenanceError("Ghostty surface staged leaf changed during verification")


def _revalidate_ghostty_surface_snapshot(snapshot: dict[str, object]) -> None:
    try:
        _revalidate_ghostty_surface_snapshot_unchecked(snapshot)
    except OSError as error:
        raise ProvenanceError(
            f"Ghostty surface staged snapshot became inaccessible: {error}"
        ) from error


def _close_ghostty_surface_snapshot(snapshot: dict[str, object] | None) -> None:
    if snapshot is None:
        return
    descriptors = snapshot.get("descriptors", ())
    assert isinstance(descriptors, tuple)
    for descriptor in reversed(descriptors):
        os.close(descriptor)


def _capture_ghostty_surface_evidence(
    arguments: ProvenanceArguments,
    *,
    retain_descriptors: bool = False,
) -> tuple[dict[str, object], dict[str, object] | None]:
    manifest_path = arguments.ghostty_surface_manifest
    staged_root_path = arguments.ghostty_surface_staged_root
    if manifest_path is None or staged_root_path is None:
        raise ProvenanceError(
            "Release qualification requires the Ghostty surface source manifest and staged root"
        )
    manifest, manifest_bytes = _ghostty_surface_manifest(
        manifest_path.resolve(strict=True)
    )
    if not staged_root_path.is_absolute() or ".." in staged_root_path.parts:
        raise ProvenanceError("Ghostty surface staged root must use an absolute canonical path")
    observed: dict[str, tuple[str, int, str]] = {}
    descriptors: list[int] = []
    snapshot: dict[str, object] | None = None
    try:
        chain, ancestry_links, _root_shared_fields, filesystem_root_fields = (
            _open_provenance_root(
                staged_root_path,
                "Ghostty surface staged root",
            )
        )
        descriptors.extend(chain)
        root_descriptor = chain[-1]
        root_fields = _provenance_stable_fields(os.fstat(root_descriptor))
        _require_exact_directory_entries(
            root_descriptor,
            {GHOSTTY_SURFACE_STAGED_DESCRIPTOR, "Headers", "libghostty-internal.a"},
            "Ghostty surface staged root",
        )
        headers_descriptor, headers_fields = _open_provenance_directory_at(
            root_descriptor,
            "Headers",
            "Ghostty surface staged Headers",
        )
        descriptors.append(headers_descriptor)
        _require_exact_directory_entries(
            headers_descriptor,
            {"ghostty.h", "module.modulemap"},
            "Ghostty surface staged Headers",
        )
        descriptor_bytes, descriptor_fields = _read_provenance_file_at(
            root_descriptor,
            GHOSTTY_SURFACE_STAGED_DESCRIPTOR,
            GHOSTTY_SURFACE_STAGED_DESCRIPTOR_MAX_BYTES,
            "Ghostty surface staged descriptor",
        )
        archive_digest, archive_size, _payload, archive_fields = (
            _digest_provenance_file_at(
                root_descriptor,
                "libghostty-internal.a",
                MAX_SINGLE_INPUT_BYTES,
                "Ghostty surface staged archive",
            )
        )
        header_digest, header_size, _payload, header_fields = (
            _digest_provenance_file_at(
                headers_descriptor,
                "ghostty.h",
                MAX_SINGLE_INPUT_BYTES,
                "Ghostty surface staged header",
            )
        )
        module_digest, module_size, _payload, module_fields = (
            _digest_provenance_file_at(
                headers_descriptor,
                "module.modulemap",
                MAX_SINGLE_INPUT_BYTES,
                "Ghostty surface staged module map",
            )
        )
        observed = {
            GHOSTTY_SURFACE_STAGED_DESCRIPTOR: (
                GHOSTTY_SURFACE_STAGED_DESCRIPTOR,
                len(descriptor_bytes),
                hashlib.sha256(descriptor_bytes).hexdigest(),
            ),
            "libghostty-internal.a": (
                "libghostty-internal.a",
                archive_size,
                archive_digest,
            ),
            "Headers/ghostty.h": (
                "Headers/ghostty.h",
                header_size,
                header_digest,
            ),
            "Headers/module.modulemap": (
                "Headers/module.modulemap",
                module_size,
                module_digest,
            ),
        }
        snapshot = {
            "descriptors": tuple(descriptors),
            "root_descriptor": root_descriptor,
            "root_fields": root_fields,
            "headers_descriptor": headers_descriptor,
            "headers_fields": headers_fields,
            "filesystem_root": (chain[0], filesystem_root_fields),
            "ancestry_links": ancestry_links,
            "headers_link": (
                root_descriptor,
                "Headers",
                headers_descriptor,
                headers_fields,
            ),
            "file_links": (
                (root_descriptor, GHOSTTY_SURFACE_STAGED_DESCRIPTOR, descriptor_fields),
                (root_descriptor, "libghostty-internal.a", archive_fields),
                (headers_descriptor, "ghostty.h", header_fields),
                (headers_descriptor, "module.modulemap", module_fields),
            ),
        }
        _revalidate_ghostty_surface_snapshot(snapshot)
    except BaseException:
        for descriptor in reversed(descriptors):
            os.close(descriptor)
        raise
    try:
        for relative, manifest_field in GHOSTTY_SURFACE_STAGED_LEAF_FIELDS.items():
            if observed[relative][2] != manifest[manifest_field]:
                raise ProvenanceError(
                    "Ghostty surface staged "
                    f"{Path(relative).name} differs from the schema-3 source manifest"
                )
        source_manifest_sha256 = hashlib.sha256(manifest_bytes).hexdigest()
        _validate_ghostty_surface_staged_descriptor(
            descriptor_bytes,
            source_manifest_sha256=source_manifest_sha256,
            observed=observed,
        )

        staged_tree = hashlib.sha256()
        for relative, size, digest in sorted(
            observed.values(), key=lambda item: os.fsencode(item[0])
        ):
            staged_tree.update(relative.encode("utf-8"))
            staged_tree.update(b"\0")
            staged_tree.update(str(size).encode("ascii"))
            staged_tree.update(b"\0")
            staged_tree.update(digest.encode("ascii"))
            staged_tree.update(b"\0")
        descriptor = observed[GHOSTTY_SURFACE_STAGED_DESCRIPTOR]
        archive = observed["libghostty-internal.a"]
        header = observed["Headers/ghostty.h"]
        module_map = observed["Headers/module.modulemap"]
        evidence = {
            "ghostty_surface_compilation_condition": GHOSTTY_SURFACE_COMPILATION_CONDITION,
            "ghostty_surface_source_manifest_sha256": source_manifest_sha256,
            "ghostty_surface_source_revision": manifest["source_revision"],
            "ghostty_surface_source_tree": manifest["source_tree"],
            "ghostty_surface_source_sha256": manifest["source_sha256"],
            "ghostty_surface_external_io_abi_version": int(
                manifest["external_io_abi_version"]
            ),
            "ghostty_surface_build_profile_sha256": manifest["build_profile_sha256"],
            "ghostty_surface_staged_tree_sha256": staged_tree.hexdigest(),
            "ghostty_surface_staged_descriptor_relative_path": descriptor[0],
            "ghostty_surface_staged_descriptor_sha256": descriptor[2],
            "ghostty_surface_archive_relative_path": archive[0],
            "ghostty_surface_archive_sha256": archive[2],
            "ghostty_surface_header_relative_path": header[0],
            "ghostty_surface_header_sha256": header[2],
            "ghostty_surface_module_map_relative_path": module_map[0],
            "ghostty_surface_module_map_sha256": module_map[2],
        }
    except BaseException:
        _close_ghostty_surface_snapshot(snapshot)
        raise
    assert snapshot is not None
    if retain_descriptors:
        return evidence, snapshot
    _close_ghostty_surface_snapshot(snapshot)
    return evidence, None


def _retained_release_evidence(arguments: ProvenanceArguments) -> dict[str, Any]:
    return _release_admission.retained_release_evidence(
        _admitted_release(arguments.repository_root.resolve(strict=True)), _receipt_json)


def ghostty_surface_evidence(
    arguments: ProvenanceArguments,
) -> dict[str, object]:
    if _admitted_release(arguments.repository_root.resolve(strict=True)) is not None:
        return {key: value for key, value in _retained_release_evidence(arguments).items()
                if key.startswith("ghostty_surface_")}
    evidence, _snapshot = _capture_ghostty_surface_evidence(arguments)
    return evidence


APPLE_SILICON_CRITICAL_FILE_RELATIVE_PATHS = (
    "share/sleigh/specfiles/Ghidra/Processors/AARCH64/data/languages/AppleSilicon.ldefs",
    "share/sleigh/specfiles/Ghidra/Processors/AARCH64/data/languages/AARCH64_AppleSilicon.sla",
    "share/sleigh/specfiles/Ghidra/Processors/AARCH64/data/languages/AARCH64.pspec",
    "share/sleigh/specfiles/Ghidra/Processors/AARCH64/data/languages/AARCH64_apple.cspec",
)


def _require_truthful_embedded_critical_files(
    recorded: object,
    observed_hashes: dict[str, str],
) -> None:
    """Validate the shipped critical summary against the already-hashed package tree."""

    if not isinstance(recorded, dict) or not 1 <= len(recorded) <= 128:
        raise ProvenanceError(
            "embedded native decompiler critical-file identity must contain 1 through 128 entries"
        )
    for relative, digest in recorded.items():
        if (
            not isinstance(relative, str)
            or not isinstance(digest, str)
            or re.fullmatch(r"[0-9a-f]{64}", digest) is None
        ):
            raise ProvenanceError("embedded native decompiler critical-file identity is malformed")
        if observed_hashes.get(relative) != digest:
            raise ProvenanceError(
                f"embedded native decompiler critical-file identity differs for {relative}"
            )
    missing = [
        relative
        for relative in APPLE_SILICON_CRITICAL_FILE_RELATIVE_PATHS
        if relative not in observed_hashes
    ]
    if missing:
        raise ProvenanceError(
            "embedded native decompiler package is missing frozen Apple Silicon resource "
            + missing[0]
        )


def _embedded_package_evidence_from_snapshot(
    snapshot: dict[str, object],
    golden: dict[str, object],
    verified_materialization: dict[str, Any],
) -> dict[str, str]:
    records = snapshot["package_records"]
    manifest_bytes = snapshot["manifest_bytes"]
    assert isinstance(records, tuple)
    assert isinstance(manifest_bytes, bytes)
    top_level = {record[0].split("/", 1)[0] for record in records}
    record_kinds = {record[0]: record[1] for record in records}
    if (
        top_level != {"MATERIALIZATION.json", "package"}
        or record_kinds.get("MATERIALIZATION.json") != "file"
        or record_kinds.get("package") != "directory"
    ):
        raise ProvenanceError("embedded native decompiler package has unexpected root entries")
    if manifest_bytes != canonical_json(verified_materialization):
        raise ProvenanceError(
            "embedded native decompiler materialization differs from the strict verified SLEIGH input"
        )
    package_record = verified_materialization.get("package")
    package_keys = {
        "relativeRoot",
        "cmakeConfigRelativePath",
        "processorSpecRelativeRoot",
        "decompilerLibraryRelativePath",
        "sleighLibraryRelativePath",
        "fileCount",
        "totalBytes",
        "treeSha256",
        "criticalFileSha256",
    }
    if not isinstance(package_record, dict) or set(package_record) != package_keys:
        raise ProvenanceError("embedded native decompiler package identity is malformed")
    if (
        package_record["relativeRoot"] != "package"
        or package_record["decompilerLibraryRelativePath"] != "lib/libdecomp.a"
        or package_record["sleighLibraryRelativePath"] != "lib/libsla.a"
    ):
        raise ProvenanceError("embedded native decompiler package names unexpected native inputs")

    files: list[tuple[str, int, str]] = []
    for relative, kind, fields, digest in records:
        if not relative.startswith("package/") or kind != "file":
            continue
        if digest is None:
            raise ProvenanceError("embedded native decompiler package file lacks a digest")
        files.append((relative.removeprefix("package/"), fields[4], digest))
    files.sort(key=lambda item: os.fsencode(item[0]))
    tree_digest = hashlib.sha256()
    observed_hashes: dict[str, str] = {}
    for relative, size, digest in files:
        observed_hashes[relative] = digest
        tree_digest.update(relative.encode("utf-8"))
        tree_digest.update(b"\0")
        tree_digest.update(str(size).encode("ascii"))
        tree_digest.update(b"\0")
        tree_digest.update(digest.encode("ascii"))
        tree_digest.update(b"\0")
    observed_tree_digest = tree_digest.hexdigest()
    if (
        package_record["fileCount"] != len(files)
        or package_record["totalBytes"] != sum(size for _relative, size, _digest in files)
        or package_record["treeSha256"] != observed_tree_digest
    ):
        raise ProvenanceError("embedded native decompiler package tree differs from its manifest")
    _require_truthful_embedded_critical_files(
        package_record["criticalFileSha256"], observed_hashes
    )
    decompiler_digest = observed_hashes.get("lib/libdecomp.a")
    sleigh_digest = observed_hashes.get("lib/libsla.a")
    if decompiler_digest is None or sleigh_digest is None:
        raise ProvenanceError("embedded native decompiler archives are missing")
    evidence = {
        "native_decompiler_embedded_manifest_sha256": hashlib.sha256(manifest_bytes).hexdigest(),
        "native_decompiler_embedded_tree_sha256": observed_tree_digest,
        "native_decompiler_embedded_decompiler_archive_sha256": decompiler_digest,
        "native_decompiler_embedded_sleigh_archive_sha256": sleigh_digest,
    }
    for key, observed in {
        "materializationManifestSHA256": evidence["native_decompiler_embedded_manifest_sha256"],
        "materializationTreeSHA256": evidence["native_decompiler_embedded_tree_sha256"],
        "decompilerArchiveSHA256": decompiler_digest,
        "sleighArchiveSHA256": sleigh_digest,
    }.items():
        if golden.get(key) != observed:
            raise ProvenanceError(
                f"embedded native decompiler package {key} differs from the golden result"
            )
    return evidence


def _embedded_service_evidence_from_snapshot(
    snapshot: dict[str, object],
) -> dict[str, str]:
    info_bytes = snapshot["info_bytes"]
    executable_digest = snapshot["executable_digest"]
    code_resources_digest = snapshot["code_resources_digest"]
    assert isinstance(info_bytes, bytes)
    assert isinstance(executable_digest, str)
    assert isinstance(code_resources_digest, str)
    try:
        info = plistlib.loads(info_bytes)
    except plistlib.InvalidFileException as error:
        raise ProvenanceError("embedded native decompiler service Info.plist is malformed") from error
    if (
        not isinstance(info, dict)
        or info.get("CFBundleIdentifier") != "org.macscope.app.NativeDecompiler"
        or info.get("CFBundleExecutable") != "NativeDecompilerXPCService"
        or info.get("CFBundlePackageType") != "XPC!"
    ):
        raise ProvenanceError("embedded native decompiler service identity is unexpected")
    return {
        "native_decompiler_embedded_service_bundle_identifier": info["CFBundleIdentifier"],
        "native_decompiler_embedded_service_info_plist_sha256": hashlib.sha256(info_bytes).hexdigest(),
        "native_decompiler_embedded_service_executable_sha256": executable_digest,
        "native_decompiler_embedded_service_code_resources_sha256": code_resources_digest,
    }


def native_decompiler_golden_evidence(
    arguments: ProvenanceArguments,
    *,
    wrapper_source_sha256: str | None = None,
    golden_source_sha256: str | None = None,
    head_commit: str | None = None,
    tools: dict[str, str],
    verified_sleigh: dict[str, Any] | None = None,
) -> dict[str, object]:
    def expected_identity(wrapper: str, golden: str) -> dict[str, str]:
        return {
            "architecture": arguments.architectures,
            "backendID": "ghidra-native-decompiler",
            "deploymentTarget": arguments.deployment_target,
            "engineVersion": "12.1.2",
            "engineGitRevision": "c0f584bf229fffba61b36431f3ce30c0c3e4e682",
            "wrapperVersion": EXPECTED_NATIVE_DECOMPILER_WRAPPER_VERSION,
            "wrapperGitRevision": wrapper,
            "goldenSourceSHA256": golden,
            "xcodeVersion": tools["xcode_version"],
            "xcodeBuild": tools["xcode_build"],
            "swiftCompilerVersion": tools["swift_compiler_version"],
            "swiftTargetTriple": tools["swift_target_triple"],
            "sdkName": arguments.sdk_name,
            "sdkVersion": arguments.sdk_version,
            "sdkBuild": arguments.sdk_build,
        }

    app_root, result_path = _derived_embedded_native_decompiler_paths(arguments)
    admitted = _admitted_release(arguments.repository_root.resolve(strict=True))
    if admitted is not None and admitted.get("current_release"):
        native = admitted["native"]
        evidence = admitted["native_helper"].runtime_evidence(native, result_path)
        retained = evidence.get("native_decompiler_golden_result")
        wrapper, golden = native_decompiler_source_identities(arguments.repository_root.resolve(strict=True))
        if not isinstance(retained, dict) or any(
                retained.get(key) != value for key, value in expected_identity(wrapper, golden).items()):
            raise ProvenanceError("retained native golden identity or toolchain differs")
        return evidence
    if admitted is not None:
        # Package and golden outputs are retained, while the newly compiled signed
        # service has its own fresh output identity. Do not rehash retained leaves.
        wrapper, golden = native_decompiler_source_identities(arguments.repository_root.resolve(strict=True))
        old_inputs = Path(admitted["overlay"]["retained_native_qualification_inputs"])
        old_provenance = _receipt_json(old_inputs.parent / "DerivedData/Build/Products/Debug/MacScope.app/Contents/Resources/MacScopeBuildProvenance.json", "retained Debug provenance")
        retained = old_provenance.get("native_decompiler_golden_result")
        if not isinstance(retained, dict) or retained != admitted["native_golden_result"]:
            raise ProvenanceError("retained native provenance differs from the admitted golden result")
        if any(retained.get(key) != value for key, value in expected_identity(wrapper, golden).items()):
            raise ProvenanceError("retained native golden identity or toolchain differs")
        evidence = {key: value for key, value in old_provenance.items()
                    if key.startswith("native_decompiler_") and not key.startswith("native_decompiler_embedded_service_")}
        evidence.update(embedded_native_decompiler_service_evidence(result_path))
        return evidence
    snapshot = _capture_embedded_native_decompiler_snapshot(app_root)
    payload_bytes = snapshot["golden_bytes"]
    assert isinstance(payload_bytes, bytes)
    if wrapper_source_sha256 is None or golden_source_sha256 is None:
        computed_wrapper, computed_golden = native_decompiler_source_identities(
            arguments.repository_root
        )
        if wrapper_source_sha256 is None:
            wrapper_source_sha256 = computed_wrapper
        if golden_source_sha256 is None:
            golden_source_sha256 = computed_golden

    exact_values = expected_identity(wrapper_source_sha256, golden_source_sha256)
    try:
        value = validate_golden_payload(payload_bytes, expected_identity=exact_values)
    except _golden_validator.GoldenEvidenceError as error:
        raise ProvenanceError("embedded native decompiler " + str(error)) from error
    if verified_sleigh is None:
        verified_sleigh = verified_sleigh_materialization(
            arguments,
            materialization_root=(
                None
                if arguments.configuration == "Release"
                else result_path.parent / "NativeDecompilerPackage"
            ),
        )
    package_evidence = _embedded_package_evidence_from_snapshot(
        snapshot,
        value,
        verified_sleigh,
    )
    service_evidence = _embedded_service_evidence_from_snapshot(snapshot)
    repeated_snapshot = _capture_embedded_native_decompiler_snapshot(app_root)
    if repeated_snapshot != snapshot:
        raise ProvenanceError(
            "embedded native decompiler package or service changed after its stable snapshot"
        )
    return {
        "native_decompiler_golden_result_sha256": hashlib.sha256(payload_bytes).hexdigest(),
        "native_decompiler_golden_result": value,
        **package_evidence,
        **service_evidence,
    }


def native_decompiler_source_identities(repository_root: Path) -> tuple[str, str]:
    admitted = _admitted_release(repository_root.resolve(strict=True))
    if admitted is not None and admitted.get("current_release"):
        golden = admitted["native"]["golden"]
        return golden["wrapperGitRevision"], golden["goldenSourceSHA256"]
    if admitted is not None:
        overlay = admitted["overlay"]
        old_inputs_path = Path(overlay["retained_native_qualification_inputs"])
        old_inputs = _receipt_json(old_inputs_path, "retained native qualification inputs")
        old_root = Path(old_inputs["build_source_root"])
        if old_root != old_inputs_path.parent / "source":
            raise ProvenanceError("retained native qualification source/run differs")
        old_records = _admitted_source_records(old_root, old_inputs["source_identity"])
        golden_path = Path(overlay["retained_native_golden_result"])
        if not golden_path.is_relative_to(old_inputs_path.parent / "DerivedData/Build/Products"):
            raise ProvenanceError("retained native golden must belong to admitted run products")
        golden = _receipt_json(golden_path, "retained native golden result")
        helper_path = repository_root / "Scripts/native-decompiler-xpc/native_decompiler_source_identity.py"
        namespace = {"__name__": "release_reused_native_profiles", "__file__": str(helper_path)}
        exec(compile(read_bounded_regular_file(helper_path, 128 * 1024, "native profile declarations"), str(helper_path), "exec"), namespace)
        for profile in ("wrapper", "golden"):
            paths = namespace["profile_paths"](repository_root, profile)
            old_paths = namespace["profile_paths"](old_root, profile)
            if paths != old_paths or any(admitted["records"].get(path) != old_records.get(path) for path in paths):
                raise ProvenanceError("retained native golden source profile differs: " + profile)
        values = (golden.get("wrapperGitRevision"), golden.get("goldenSourceSHA256"))
        if any(not isinstance(value, str) or HEX_SHA256.fullmatch(value) is None for value in values):
            raise ProvenanceError("retained native golden has malformed source identities")
        # Carry the already admitted JSON to its consumer; do not read or hash
        # the retained golden leaf a second time to bind provenance to it.
        admitted["native_golden_result"] = golden
        return values
    helper = (
        repository_root
        / "Scripts"
        / "native-decompiler-xpc"
        / "native_decompiler_source_identity.py"
    )
    metadata = helper.lstat()
    if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISREG(metadata.st_mode):
        raise ProvenanceError("native decompiler source identity helper is unavailable")
    specification = importlib.util.spec_from_file_location(
        "macscope_native_decompiler_source_identity",
        helper,
    )
    if specification is None or specification.loader is None:
        raise ProvenanceError("could not load native decompiler source identity helper")
    module = importlib.util.module_from_spec(specification)
    previous_dont_write_bytecode = sys.dont_write_bytecode
    try:
        sys.dont_write_bytecode = True
        specification.loader.exec_module(module)
        wrapper = module.profile_digest(repository_root, "wrapper")
        golden = module.profile_digest(repository_root, "golden")
    except Exception as error:
        raise ProvenanceError("could not compute native decompiler source identities") from error
    finally:
        sys.dont_write_bytecode = previous_dont_write_bytecode
    if not all(isinstance(value, str) and re.fullmatch(r"[0-9a-f]{64}", value) for value in (wrapper, golden)):
        raise ProvenanceError("native decompiler source identities are invalid")
    return wrapper, golden


def machokit_materialization_evidence(
    repository_root: Path,
    materialization_root: Path,
    *,
    identity_verifier: Callable[[Path], dict[str, str]] | None = None,
) -> dict[str, str]:
    """Verify and seal the one permitted direct-source MachOKit closure.

    The root itself remains an operator-local, untracked dependency input.  The
    signed provenance resource therefore records only a hash of its resolved
    path, while the independent verifier proves its immutable provider,
    transitive-source, direct-source-only, and full-tree identities.
    """
    try:
        metadata = materialization_root.lstat()
    except OSError as error:
        raise ProvenanceError(f"MachOKit materialization root is unavailable: {error}") from error
    if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISDIR(metadata.st_mode):
        raise ProvenanceError("MachOKit materialization root must be an ordinary directory")
    root = materialization_root.resolve(strict=True)

    admitted = _admitted_release(repository_root.resolve(strict=True))
    if admitted is not None:
        if root != admitted["run"] / "private-machokit-input":
            raise ProvenanceError("MachOKit root differs from admitted qualification run")
        manifest = _receipt_json(root / "MATERIALIZATION.json", "admitted MachOKit manifest")
        provider = manifest.get("provider", {})
        observed_identity = {
            "version": provider.get("version"), "revision": provider.get("revision"),
            "source_archive_sha256": provider.get("source_archive_sha256"),
            "upstream_tree_sha256": provider.get("upstream_tree_sha256"),
            "materialization_tree_sha256": manifest.get("tree_sha256"),
            "governed_source_identity": manifest.get("governed_source_identity"),
        }
    elif identity_verifier is None:
        helper = repository_root / "Scripts" / "machokit_source_identity.py"
        try:
            helper_metadata = helper.lstat()
        except OSError as error:
            raise ProvenanceError("MachOKit source identity helper is unavailable") from error
        if stat.S_ISLNK(helper_metadata.st_mode) or not stat.S_ISREG(helper_metadata.st_mode):
            raise ProvenanceError("MachOKit source identity helper is unavailable")
        specification = importlib.util.spec_from_file_location(
            "macscope_machokit_source_identity",
            helper,
        )
        if specification is None or specification.loader is None:
            raise ProvenanceError("could not load MachOKit source identity helper")
        module = importlib.util.module_from_spec(specification)
        previous_dont_write_bytecode = sys.dont_write_bytecode
        module_name = specification.name
        previous_module = sys.modules.get(module_name)
        try:
            sys.dont_write_bytecode = True
            # dataclasses resolves forward annotations via sys.modules while the
            # helper defines its immutable component identities.
            sys.modules[module_name] = module
            specification.loader.exec_module(module)
            module.verify_root(root, quiet=True)
            observed_identity = {
                "version": module.MACHOKIT_VERSION,
                "revision": module.MACHOKIT_REVISION,
                "source_archive_sha256": module.MACHOKIT_ARCHIVE_SHA256,
                "upstream_tree_sha256": module.MACHOKIT_UPSTREAM_TREE_SHA256,
                "materialization_tree_sha256": module.MATERIALIZATION_TREE_SHA256,
                "governed_source_identity": module.GOVERNED_SOURCE_IDENTITY,
            }
        except Exception as error:
            raise ProvenanceError("MachOKit materialization identity verification failed") from error
        finally:
            sys.dont_write_bytecode = previous_dont_write_bytecode
            if previous_module is None:
                sys.modules.pop(module_name, None)
            else:
                sys.modules[module_name] = previous_module
    else:
        observed_identity = identity_verifier(root)

    if observed_identity != MACHOKIT_EXPECTED_IDENTITY:
        raise ProvenanceError("MachOKit materialization identity differs from the reviewed contract")
    manifest = root / "MATERIALIZATION.json"
    manifest_bytes = read_bounded_regular_file(
        manifest,
        MAX_MACHOKIT_MATERIALIZATION_MANIFEST_BYTES,
        "MachOKit materialization manifest",
    )
    return {
        "machokit_materialization_root_sha256": hashlib.sha256(
            os.fsencode(str(root))
        ).hexdigest(),
        "machokit_version": MACHOKIT_EXPECTED_IDENTITY["version"],
        "machokit_revision": MACHOKIT_EXPECTED_IDENTITY["revision"],
        "machokit_source_archive_sha256": MACHOKIT_EXPECTED_IDENTITY[
            "source_archive_sha256"
        ],
        "machokit_upstream_tree_sha256": MACHOKIT_EXPECTED_IDENTITY[
            "upstream_tree_sha256"
        ],
        "machokit_materialization_tree_sha256": MACHOKIT_EXPECTED_IDENTITY[
            "materialization_tree_sha256"
        ],
        "machokit_governed_source_identity": MACHOKIT_EXPECTED_IDENTITY[
            "governed_source_identity"
        ],
        "machokit_materialization_manifest_sha256": (
            admitted["cache_inputs"]["machokit_manifest_sha256"] if admitted is not None and admitted.get("cache_release") else
            _receipt_json(Path(admitted["overlay"]["retained_release_qualification_inputs"]).parent / "DerivedData/Build/Products/Release/MacScope.app/Contents/Resources/MacScopeBuildProvenance.json", "retained MachOKit provenance")["machokit_materialization_manifest_sha256"]
            if admitted is not None else hashlib.sha256(manifest_bytes).hexdigest()
        ),
    }


def machokit_analysis_worker_evidence(
    repository_root: Path,
    executable: Path,
    *,
    identity_verifier: Callable[[Path], dict[str, str]] | None = None,
) -> dict[str, object]:
    """Verify and seal the built worker's exact compiled MachOKit identity.

    The verifier scans the executable itself; no caller-provided receipt can
    stand in for those bytes.  Provenance brackets its own content hash with
    two verifier passes and a stable path identity so the marker and digest
    describe the same singly linked ordinary build artifact.
    """

    if not executable.is_absolute():
        raise ProvenanceError(
            "AnalysisWorkerXPCService executable path must be absolute"
        )
    try:
        before = executable.lstat()
    except OSError as error:
        raise ProvenanceError(
            f"AnalysisWorkerXPCService executable is unavailable: {error}"
        ) from error
    if (
        stat.S_ISLNK(before.st_mode)
        or not stat.S_ISREG(before.st_mode)
        or before.st_nlink != 1
        or before.st_size <= 0
    ):
        raise ProvenanceError(
            "AnalysisWorkerXPCService executable must be nonempty, ordinary, and singly linked"
        )

    if identity_verifier is None:
        helper = repository_root / "Scripts/verify_machokit_analysis_worker_identity.py"
        try:
            helper_metadata = helper.lstat()
        except OSError as error:
            raise ProvenanceError(
                "MachOKit compiled-identity verifier is unavailable"
            ) from error
        if (
            stat.S_ISLNK(helper_metadata.st_mode)
            or not stat.S_ISREG(helper_metadata.st_mode)
            or helper_metadata.st_nlink != 1
        ):
            raise ProvenanceError(
                "MachOKit compiled-identity verifier must be an ordinary singly linked file"
            )
        specification = importlib.util.spec_from_file_location(
            "macscope_machokit_compiled_identity_verifier",
            helper,
        )
        if specification is None or specification.loader is None:
            raise ProvenanceError("could not load MachOKit compiled-identity verifier")
        module = importlib.util.module_from_spec(specification)
        previous_dont_write_bytecode = sys.dont_write_bytecode
        try:
            sys.dont_write_bytecode = True
            specification.loader.exec_module(module)
            identity_verifier = module.verify_analysis_worker_executable
        except Exception as error:
            raise ProvenanceError(
                "could not load MachOKit compiled-identity verifier"
            ) from error
        finally:
            sys.dont_write_bytecode = previous_dont_write_bytecode

    admitted = _admitted_release(repository_root.resolve(strict=True))
    current = admitted is not None and admitted.get("current_release")
    if current:
        admitted["lease"].file(executable)
    try:
        if current:
            worker_bytes = read_bounded_regular_file(executable, 512 * 1024 * 1024, "new signed AnalysisWorker")
            first_identity = module.verify_analysis_worker_payload(worker_bytes)
            executable_digest, executable_size = hashlib.sha256(worker_bytes).digest(), len(worker_bytes)
            second_identity = first_identity
        else:
            first_identity = identity_verifier(executable)
            executable_digest, executable_size = sha256_file(executable)
            second_identity = identity_verifier(executable)
        after = executable.lstat()
    except Exception as error:
        raise ProvenanceError(
            f"AnalysisWorker MachOKit compiled identity is invalid: {error}"
        ) from error

    expected_identity = {
        "schema": "macscope-machokit-compiled-identity-v1",
        "revision": MACHOKIT_EXPECTED_IDENTITY["revision"],
        "governed_source_identity": MACHOKIT_EXPECTED_IDENTITY[
            "governed_source_identity"
        ],
    }
    stable_fields = (
        "st_dev",
        "st_ino",
        "st_mode",
        "st_nlink",
        "st_size",
        "st_mtime_ns",
        "st_ctime_ns",
    )
    if (
        first_identity != expected_identity
        or second_identity != expected_identity
        or any(getattr(before, field) != getattr(after, field) for field in stable_fields)
        or executable_size != before.st_size
    ):
        raise ProvenanceError(
            "AnalysisWorker MachOKit compiled identity differs from the reviewed artifact contract"
        )
    return {
        "machokit_analysis_worker_compiled_identity": expected_identity,
        "machokit_analysis_worker_executable_sha256": executable_digest.hex(),
        "machokit_analysis_worker_executable_size": executable_size,
    }


def embedded_native_decompiler_package_evidence(
    golden_result_path: Path,
    golden: dict[str, object],
) -> dict[str, str]:
    materialization_root = golden_result_path.parent / "NativeDecompilerPackage"
    try:
        root_metadata = materialization_root.lstat()
    except OSError as error:
        raise ProvenanceError(f"embedded native decompiler package is missing: {error}") from error
    if stat.S_ISLNK(root_metadata.st_mode) or not stat.S_ISDIR(root_metadata.st_mode):
        raise ProvenanceError("embedded native decompiler package must be an ordinary directory")
    observed_root_entries = {path.name for path in materialization_root.iterdir()}
    if observed_root_entries != {"MATERIALIZATION.json", "package"}:
        raise ProvenanceError("embedded native decompiler package has unexpected root entries")

    manifest_path = materialization_root / "MATERIALIZATION.json"
    manifest_metadata = manifest_path.lstat()
    if (
        stat.S_ISLNK(manifest_metadata.st_mode)
        or not stat.S_ISREG(manifest_metadata.st_mode)
        or manifest_metadata.st_nlink != 1
    ):
        raise ProvenanceError(
            "embedded native decompiler materialization manifest must be ordinary and singly linked"
        )
    manifest_bytes = read_bounded_regular_file(
        manifest_path,
        MAX_NATIVE_MATERIALIZATION_MANIFEST_BYTES,
        "embedded native decompiler materialization manifest",
    )
    try:
        manifest = json.loads(manifest_bytes)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ProvenanceError("embedded native decompiler materialization manifest is malformed") from error
    if not isinstance(manifest, dict) or set(manifest) != {
        "schemaVersion",
        "componentId",
        "sleighVersion",
        "sleighGitRevision",
        "ghidraVersion",
        "ghidraGitRevision",
        "artifact",
        "package",
    }:
        raise ProvenanceError("embedded native decompiler materialization manifest has unsupported fields")
    canonical_manifest = (
        json.dumps(manifest, ensure_ascii=True, allow_nan=False, sort_keys=True, separators=(",", ":"))
        + "\n"
    ).encode("utf-8")
    if manifest_bytes != canonical_manifest:
        raise ProvenanceError("embedded native decompiler materialization manifest is not canonical JSON")
    expected_identity = {
        "schemaVersion": 1,
        "componentId": "sleigh-native-dcp03b4",
        "sleighVersion": "12.1.2",
        "sleighGitRevision": "bfd38a983b4aa53dd386365e1df5ed5499b7e2fb",
        "ghidraVersion": "12.1.2",
        "ghidraGitRevision": "c0f584bf229fffba61b36431f3ce30c0c3e4e682",
    }
    for key, expected in expected_identity.items():
        if manifest[key] != expected:
            raise ProvenanceError(
                f"embedded native decompiler materialization manifest has unexpected {key}"
            )
    artifact = manifest["artifact"]
    if not isinstance(artifact, dict) or set(artifact) != {"platform", "filename", "url", "sha256"}:
        raise ProvenanceError("embedded native decompiler artifact identity is malformed")
    if artifact != {
        "platform": "macos-arm64",
        "filename": "macOS-sleigh-12.1.2-1.arm64.tar.gz",
        "url": (
            "https://github.com/lifting-bits/sleigh/releases/download/v12.1.2/"
            "macOS-sleigh-12.1.2-1.arm64.tar.gz"
        ),
        "sha256": "e1391c811de7b2d79c9e8a1f6f74cd9ade23baf55deebd75c626a3152e5e451a",
    }:
        raise ProvenanceError("embedded native decompiler artifact identity is not approved")

    package_record = manifest["package"]
    package_keys = {
        "relativeRoot",
        "cmakeConfigRelativePath",
        "processorSpecRelativeRoot",
        "decompilerLibraryRelativePath",
        "sleighLibraryRelativePath",
        "fileCount",
        "totalBytes",
        "treeSha256",
        "criticalFileSha256",
    }
    if not isinstance(package_record, dict) or set(package_record) != package_keys:
        raise ProvenanceError("embedded native decompiler package identity is malformed")
    if (
        package_record["relativeRoot"] != "package"
        or package_record["decompilerLibraryRelativePath"] != "lib/libdecomp.a"
        or package_record["sleighLibraryRelativePath"] != "lib/libsla.a"
    ):
        raise ProvenanceError("embedded native decompiler package names unexpected native inputs")

    package_root = materialization_root / "package"
    try:
        package_root_metadata = package_root.lstat()
    except OSError as error:
        raise ProvenanceError(f"embedded native decompiler package tree is missing: {error}") from error
    if stat.S_ISLNK(package_root_metadata.st_mode) or not stat.S_ISDIR(package_root_metadata.st_mode):
        raise ProvenanceError("embedded native decompiler package tree must be an ordinary directory")

    def directory_fields(metadata: os.stat_result) -> tuple[int, ...]:
        return (
            metadata.st_dev,
            metadata.st_ino,
            metadata.st_mode,
            metadata.st_nlink,
            metadata.st_size,
            metadata.st_mtime_ns,
            metadata.st_ctime_ns,
        )

    files: list[tuple[str, Path, str, int]] = []

    def visit(directory: Path) -> None:
        before = directory.lstat()
        if stat.S_ISLNK(before.st_mode) or not stat.S_ISDIR(before.st_mode):
            raise ProvenanceError("embedded native decompiler package contains a non-directory entry")
        try:
            with os.scandir(directory) as iterator:
                entries = sorted(tuple(iterator), key=lambda item: os.fsencode(item.name))
        except OSError as error:
            raise ProvenanceError(f"embedded native decompiler package cannot be enumerated: {error}") from error
        after_listing = directory.lstat()
        if directory_fields(before) != directory_fields(after_listing):
            raise ProvenanceError("embedded native decompiler package directory changed during enumeration")
        for entry in entries:
            child = directory / entry.name
            metadata = child.lstat()
            if stat.S_ISLNK(metadata.st_mode):
                raise ProvenanceError("embedded native decompiler package contains a symbolic link")
            if stat.S_ISDIR(metadata.st_mode):
                visit(child)
                continue
            if not stat.S_ISREG(metadata.st_mode) or metadata.st_nlink != 1:
                raise ProvenanceError(
                    "embedded native decompiler package files must be ordinary and singly linked"
                )
            relative = child.relative_to(package_root).as_posix()
            relative.encode("utf-8", errors="strict")
            digest, size = sha256_file(child)
            files.append((relative, child, digest.hex(), size))
            if len(files) > 100_000:
                raise ProvenanceError("embedded native decompiler package exceeds its file-count bound")
        after = directory.lstat()
        if directory_fields(before) != directory_fields(after):
            raise ProvenanceError("embedded native decompiler package directory changed during verification")

    visit(package_root)

    files.sort(key=lambda item: os.fsencode(item[0]))
    total_bytes = sum(item[3] for item in files)
    if total_bytes > MAX_TOTAL_INPUT_BYTES:
        raise ProvenanceError("embedded native decompiler package exceeds its total-size bound")
    tree_digest = hashlib.sha256()
    observed_hashes: dict[str, str] = {}
    for relative, _path, digest, size in files:
        observed_hashes[relative] = digest
        tree_digest.update(relative.encode("utf-8"))
        tree_digest.update(b"\0")
        tree_digest.update(str(size).encode("ascii"))
        tree_digest.update(b"\0")
        tree_digest.update(digest.encode("ascii"))
        tree_digest.update(b"\0")
    observed_tree_digest = tree_digest.hexdigest()
    if (
        package_record["fileCount"] != len(files)
        or package_record["totalBytes"] != total_bytes
        or package_record["treeSha256"] != observed_tree_digest
    ):
        raise ProvenanceError("embedded native decompiler package tree differs from its manifest")

    _require_truthful_embedded_critical_files(
        package_record["criticalFileSha256"], observed_hashes
    )
    decompiler_digest = observed_hashes.get("lib/libdecomp.a")
    sleigh_digest = observed_hashes.get("lib/libsla.a")
    if decompiler_digest is None or sleigh_digest is None:
        raise ProvenanceError("embedded native decompiler archives are missing")

    evidence = {
        "native_decompiler_embedded_manifest_sha256": hashlib.sha256(manifest_bytes).hexdigest(),
        "native_decompiler_embedded_tree_sha256": observed_tree_digest,
        "native_decompiler_embedded_decompiler_archive_sha256": decompiler_digest,
        "native_decompiler_embedded_sleigh_archive_sha256": sleigh_digest,
    }
    golden_comparisons = {
        "materializationManifestSHA256": evidence["native_decompiler_embedded_manifest_sha256"],
        "materializationTreeSHA256": evidence["native_decompiler_embedded_tree_sha256"],
        "decompilerArchiveSHA256": evidence[
            "native_decompiler_embedded_decompiler_archive_sha256"
        ],
        "sleighArchiveSHA256": evidence["native_decompiler_embedded_sleigh_archive_sha256"],
    }
    for key, observed in golden_comparisons.items():
        if golden.get(key) != observed:
            raise ProvenanceError(
                f"embedded native decompiler package {key} differs from the golden result"
            )
    after_root = materialization_root.lstat()
    if (
        directory_fields(after_root)
        != directory_fields(root_metadata)
    ):
        raise ProvenanceError("embedded native decompiler package root changed during verification")
    after_package_root = package_root.lstat()
    if directory_fields(after_package_root) != directory_fields(package_root_metadata):
        raise ProvenanceError("embedded native decompiler package tree changed during verification")
    return evidence


def embedded_native_decompiler_service_evidence(
    golden_result_path: Path,
) -> dict[str, str]:
    service_root = golden_result_path.parents[2]
    if service_root.name != "NativeDecompilerXPCService.xpc":
        raise ProvenanceError("native decompiler golden result is not inside the expected service")
    root_before = service_root.lstat()
    if stat.S_ISLNK(root_before.st_mode) or not stat.S_ISDIR(root_before.st_mode):
        raise ProvenanceError("embedded native decompiler service must be an ordinary bundle")
    info_path = service_root / "Contents/Info.plist"
    executable_path = service_root / "Contents/MacOS/NativeDecompilerXPCService"
    code_resources_path = service_root / "Contents/_CodeSignature/CodeResources"
    stable_fields = (
        "st_dev",
        "st_ino",
        "st_mode",
        "st_nlink",
        "st_size",
        "st_mtime_ns",
        "st_ctime_ns",
    )
    child_paths = (
        (info_path, "embedded native decompiler service Info.plist"),
        (executable_path, "embedded native decompiler service executable"),
        (code_resources_path, "embedded native decompiler service CodeResources"),
    )
    child_metadata: dict[Path, os.stat_result] = {}
    for path, label in child_paths:
        metadata = path.lstat()
        if (
            stat.S_ISLNK(metadata.st_mode)
            or not stat.S_ISREG(metadata.st_mode)
            or metadata.st_nlink != 1
        ):
            raise ProvenanceError(f"{label} must be ordinary and singly linked")
        child_metadata[path] = metadata
    info_bytes = read_bounded_regular_file(
        info_path,
        1024 * 1024,
        "embedded native decompiler service Info.plist",
    )
    try:
        info = plistlib.loads(info_bytes)
    except plistlib.InvalidFileException as error:
        raise ProvenanceError("embedded native decompiler service Info.plist is malformed") from error
    if (
        not isinstance(info, dict)
        or info.get("CFBundleIdentifier") != "org.macscope.app.NativeDecompiler"
        or info.get("CFBundleExecutable") != "NativeDecompilerXPCService"
        or info.get("CFBundlePackageType") != "XPC!"
    ):
        raise ProvenanceError("embedded native decompiler service identity is unexpected")
    executable_digest, _ = sha256_file(executable_path)
    code_resources_digest, _ = sha256_file(code_resources_path)
    root_after = service_root.lstat()
    if any(
        getattr(root_before, field) != getattr(root_after, field)
        for field in stable_fields
    ):
        raise ProvenanceError("embedded native decompiler service changed during inventory")
    for path, label in child_paths:
        after = path.lstat()
        before = child_metadata[path]
        if any(getattr(before, field) != getattr(after, field) for field in stable_fields):
            raise ProvenanceError(f"{label} changed during service inventory")
    return {
        "native_decompiler_embedded_service_bundle_identifier": info["CFBundleIdentifier"],
        "native_decompiler_embedded_service_info_plist_sha256": hashlib.sha256(
            info_bytes
        ).hexdigest(),
        "native_decompiler_embedded_service_executable_sha256": executable_digest.hex(),
        "native_decompiler_embedded_service_code_resources_sha256": (
            code_resources_digest.hex()
        ),
    }


def release_payload(
    arguments: ProvenanceArguments,
    tool_runner: ToolRunner,
) -> dict[str, object]:
    repository_root = arguments.repository_root.resolve(strict=True)
    expected_project = repository_root / "MacScope" / "project.yml"
    project_yml = arguments.project_yml.resolve(strict=True)
    if project_yml != expected_project:
        raise ProvenanceError("Release provenance must use MacScope/project.yml")
    source_authority = resolve_source_authority(repository_root)
    head_commit = source_authority.head_commit
    head_tree = source_authority.head_tree

    project_text = project_yml.read_text(encoding="utf-8")
    project_scalars = parse_scalar_mapping(project_text)
    expected_scalars = {
        ("settings", "base", "SWIFT_VERSION"): EXPECTED_SWIFT_LANGUAGE_VERSION,
        (
            "targets",
            "MacScopeApp",
            "settings",
            "base",
            "PRODUCT_BUNDLE_IDENTIFIER",
        ): EXPECTED_APP_IDENTIFIER,
        (
            "targets",
            "AIAgentWorkerXPCService",
            "settings",
            "base",
            "PRODUCT_BUNDLE_IDENTIFIER",
        ): EXPECTED_AI_WORKER_IDENTIFIER,
    }
    for path, expected in expected_scalars.items():
        observed = project_scalars.get(path)
        if observed != expected:
            raise ProvenanceError(
                f"project.yml {'.'.join(path)} must be {expected!r}"
            )

    selected_paths = selected_source_paths(
        repository_root,
        project_yml,
        project_text,
        sealed_paths=source_authority.sealed_paths,
    )
    selected_hashes = selected_input_hashes(
        repository_root,
        selected_paths,
        sealed_records=source_authority.sealed_records,
    )
    if selected_source_paths(
        repository_root,
        project_yml,
        project_text,
        sealed_paths=source_authority.sealed_paths,
    ) != selected_paths:
        raise ProvenanceError("selected build input membership changed during generation")
    repeated_hashes = selected_input_hashes(
        repository_root,
        selected_paths,
        sealed_records=source_authority.sealed_records,
    )
    if repeated_hashes != selected_hashes:
        raise ProvenanceError("selected build inputs changed during final revalidation")
    wrapper_source_sha256, golden_source_sha256 = native_decompiler_source_identities(
        repository_root
    )
    final_source_authority = resolve_source_authority(repository_root)
    if (
        final_source_authority.head_commit != head_commit
        or final_source_authority.head_tree != head_tree
        or final_source_authority.sealed_records != source_authority.sealed_records
    ):
        raise ProvenanceError("source authority changed during provenance generation")
    tools = toolchain_evidence(arguments, repository_root, project_scalars, tool_runner)
    verified_sleigh = verified_sleigh_materialization(arguments)
    # Exact absolute paths remain in the operator qualification receipt. The signed
    # app binds the final Xcode-resolved values without leaking machine-local paths.
    ghostty_root = arguments.ghostty_source_dir.resolve(strict=True)
    sleigh_root = arguments.sleigh_materialization_root.resolve(strict=True)
    assert arguments.machokit_materialization_root is not None
    assert arguments.analysis_worker_executable is not None
    dependency_root_evidence = {
        "dependency_root_authority": "xcode-resolved-build-settings",
        "ghostty_source_dir_sha256": hashlib.sha256(
            os.fsencode(str(ghostty_root))
        ).hexdigest(),
        "sleigh_materialization_root_sha256": hashlib.sha256(
            os.fsencode(str(sleigh_root))
        ).hexdigest(),
    }

    payload: dict[str, object] = {
        "schema_version": SCHEMA_VERSION,
        "qualification_eligible": True,
        "configuration": "Release",
        "git_head_commit": head_commit,
        "git_head_tree": head_tree,
        "repository_clean": True,
        "selected_build_inputs_sha256": selected_inputs_digest(selected_hashes),
        "project_yml_sha256": selected_hashes["MacScope/project.yml"].hex(),
        **dependency_root_evidence,
        **sleigh_materialization_evidence(arguments, verified_sleigh),
        **ghostty_surface_evidence(arguments),
        **machokit_materialization_evidence(
            repository_root,
            arguments.machokit_materialization_root,
            identity_verifier=arguments.machokit_identity_verifier,
        ),
        **machokit_analysis_worker_evidence(
            repository_root,
            arguments.analysis_worker_executable,
            identity_verifier=arguments.machokit_compiled_identity_verifier,
        ),
        **third_party_evidence(repository_root, selected_hashes),
        **tools,
        **native_decompiler_golden_evidence(
            arguments,
            wrapper_source_sha256=wrapper_source_sha256,
            golden_source_sha256=golden_source_sha256,
            tools=tools,
            verified_sleigh=verified_sleigh,
        ),
        "sdk_name": arguments.sdk_name,
        "sdk_version": arguments.sdk_version,
        "sdk_build": arguments.sdk_build,
        "swift_language_version": EXPECTED_SWIFT_LANGUAGE_VERSION,
        "architecture": arguments.architectures,
        "deployment_target": arguments.deployment_target,
        "app_bundle_identifier": EXPECTED_APP_IDENTIFIER,
        "ai_worker_bundle_identifier": EXPECTED_AI_WORKER_IDENTIFIER,
    }
    admitted = _admitted_release(repository_root)
    if admitted is not None and admitted.get("cache_release"):
        payload["verification_reuse"] = {"authority": "accepted-cache-release-inputs", "source_leaves_rehashed": False,
            "dependency_leaves_reverified": False, "new_release_outputs_verified": True}
        payload["native_decompiler_source_compatibility"] = {"scope": admitted["native"]["scope"],
            "accepted_wrapper_profile": admitted["native"]["golden"]["wrapperGitRevision"],
            "accepted_golden_profile": admitted["native"]["golden"]["goldenSourceSHA256"],
            "consumer_source_updates": admitted["native"]["consumer_source_updates"]}
    if admitted is not None and not admitted.get("current_release"):
        payload["verification_reuse"] = {
            "authority": "completed-qualification-admission",
            "qualification_source_commit": head_commit,
            "qualification_source_tree": head_tree,
            "source_leaves_rehashed": False,
            "dependency_leaves_reverified": False,
            "new_release_outputs_verified": True,
        }
        payload["provenance_tool_overlay"] = admitted["overlay"]
    return payload


def generate(
    arguments: ProvenanceArguments,
    *,
    tool_runner: ToolRunner = run_tool,
) -> dict[str, object]:
    global _ADMITTED_RELEASE
    validate_arguments(arguments)
    try:
        payload = (
            release_payload(arguments, tool_runner)
            if arguments.configuration == "Release"
            else debug_runtime_payload(arguments)
        )
        encoded = canonical_json(payload)
        _write_release_provenance_at_snapshot_boundary(arguments, encoded, payload)
        return payload
    finally:
        if _ADMITTED_RELEASE is not None and _ADMITTED_RELEASE.get("current_release"):
            _release_admission.close(_ADMITTED_RELEASE)
            _ADMITTED_RELEASE = None


def parse_arguments() -> ProvenanceArguments:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo-root", type=Path, required=True)
    parser.add_argument("--project-yml", type=Path, required=True)
    parser.add_argument("--project-file-path", type=Path, required=True)
    parser.add_argument("--configuration", required=True)
    parser.add_argument("--debug-source-identity", choices=("runtime-only", "source-qualified"),
                        default="runtime-only",
                        help="Debug only: opt in to verified Git/sealed source identity; Release is unchanged")
    parser.add_argument("--native-decompiler-live-test-condition", required=True)
    parser.add_argument("--swift-active-compilation-conditions", required=True)
    parser.add_argument("--other-swift-flags", required=True)
    parser.add_argument("--architectures", required=True)
    parser.add_argument("--deployment-target", required=True)
    parser.add_argument("--sdk-name", required=True)
    parser.add_argument("--sdk-version", required=True)
    parser.add_argument("--sdk-build", required=True)
    parser.add_argument("--developer-dir", type=Path, required=True)
    parser.add_argument("--swift-executable", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--native-decompiler-golden-result", type=Path, required=True)
    parser.add_argument("--ghostty-source-dir", type=Path, required=True)
    parser.add_argument("--ghostty-surface-manifest", type=Path, required=True)
    parser.add_argument("--ghostty-surface-staged-root", type=Path, required=True)
    parser.add_argument("--sleigh-materialization-root", type=Path, required=True)
    parser.add_argument("--machokit-materialization-root", type=Path, required=True)
    parser.add_argument("--analysis-worker-executable", type=Path, required=True)
    arguments = parser.parse_args()
    return ProvenanceArguments(
        repository_root=arguments.repo_root,
        project_yml=arguments.project_yml,
        project_file_path=arguments.project_file_path,
        configuration=arguments.configuration,
        debug_source_identity=arguments.debug_source_identity,
        native_decompiler_live_test_condition=(
            arguments.native_decompiler_live_test_condition
        ),
        swift_active_compilation_conditions=arguments.swift_active_compilation_conditions,
        other_swift_flags=arguments.other_swift_flags,
        architectures=arguments.architectures,
        deployment_target=arguments.deployment_target,
        sdk_name=arguments.sdk_name,
        sdk_version=arguments.sdk_version,
        sdk_build=arguments.sdk_build,
        developer_dir=arguments.developer_dir,
        swift_executable=arguments.swift_executable,
        output=arguments.output,
        native_decompiler_golden_result=arguments.native_decompiler_golden_result,
        ghostty_source_dir=arguments.ghostty_source_dir,
        ghostty_surface_manifest=arguments.ghostty_surface_manifest,
        ghostty_surface_staged_root=arguments.ghostty_surface_staged_root,
        sleigh_materialization_root=arguments.sleigh_materialization_root,
        machokit_materialization_root=arguments.machokit_materialization_root,
        analysis_worker_executable=arguments.analysis_worker_executable,
    )


def main() -> int:
    try:
        generate(parse_arguments())
    except (OSError, ProvenanceError, UnicodeError, ValueError) as error:
        print(f"ERROR: sealed build provenance was not produced: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
