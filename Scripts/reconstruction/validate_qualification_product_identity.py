#!/usr/bin/env python3
"""Validate sealed qualification inputs, build products, and candidate bindings.

The local qualifier owns paths and dependency inputs until a Gate F candidate is
published. ``validate-inputs`` and ``validate-build`` close that prepublication
transaction without creating a second receipt schema. The legacy candidate
product CLI remains available for later Gate F consumers and now reads the
candidate and product leaves through stable, non-following descriptors.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import stat
import struct
import sys
from dataclasses import dataclass
from typing import Any


ROOT = Path(__file__).resolve().parents[2]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from Scripts.reconstruction_gate_f.canonical_json import (  # noqa: E402
    CanonicalJSONError,
    decode_canonical_bytes,
)
from Scripts.reconstruction_gate_f.schema import (  # noqa: E402
    CandidateIdentity,
    candidate_identity_sha256,
    parse_candidate_identity,
)


GIT_RE = re.compile(r"^[0-9a-f]{40}$")
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
MAX_CANDIDATE_BYTES = 4 * 1024 * 1024
MAX_RECEIPT_BYTES = 4 * 1024 * 1024
MAX_MANIFEST_BYTES = 4 * 1024 * 1024
MAX_ZIG_EXECUTABLE_BYTES = 192 * 1024 * 1024
MAX_SOURCE_RECORD_BYTES = 32 * 1024 * 1024
MAX_PLIST_BYTES = 1024 * 1024
MAX_PROVENANCE_BYTES = 4 * 1024 * 1024
MAX_STAGED_DESCRIPTOR_BYTES = 64 * 1024
STAGED_DESCRIPTOR_NAME = "STAGED_GHOSTTY_SURFACE.json"

QUALIFICATION_V4_FIELDS = frozenset(
    {
        "build_source_root",
        "dependency_cache_root",
        "dependency_network_allowed",
        "dependency_network_used",
        "ghostty_artifact_manifest_sha256",
        "ghostty_source_dir",
        "ghostty_surface_artifact_root",
        "ghostty_surface_manifest_sha256",
        "ghostty_surface_source_dir",
        "mode",
        "schema_version",
        "sleigh_materialization_manifest_sha256",
        "sleigh_materialization_root",
        "source_identity",
        "zig_executable",
    }
)
SOURCE_EXPORT_V2_FIELDS = frozenset(
    {
        "canonical_integration_commit",
        "canonical_integration_ref",
        "canonical_remote_url",
        "dependency_contract",
        "git_head_commit",
        "git_head_tree",
        "git_parent_commits",
        "repository_clean",
        "schema_version",
        "source_file_count",
        "source_files_sha256",
    }
)
STAGED_LEAVES = (
    ("archive", "libghostty-internal.a", "archive_sha256"),
    ("header", "Headers/ghostty.h", "header_sha256"),
    ("module_map", "Headers/module.modulemap", "module_map_sha256"),
)


@dataclass(frozen=True)
class ProductLayout:
    bundle_relative_path: str
    executable_relative_path: str


PRODUCT_LAYOUTS = {
    "app": ProductLayout(".", "Contents/MacOS/MacScope"),
    "native-live-app": ProductLayout(".", "Contents/MacOS/MacScope"),
    "ai-agent-worker": ProductLayout(
        "Contents/XPCServices/AIAgentWorkerXPCService.xpc",
        "Contents/MacOS/AIAgentWorkerXPCService",
    ),
    "native-decompiler": ProductLayout(
        "Contents/XPCServices/NativeDecompilerXPCService.xpc",
        "Contents/MacOS/NativeDecompilerXPCService",
    ),
}


class ProductIdentityError(RuntimeError):
    pass


@dataclass(frozen=True)
class StableFile:
    path: Path
    metadata: tuple[int, int, int, int, int, int, int]
    payload: bytes


@dataclass(frozen=True)
class QualificationInputs:
    receipt: dict[str, Any]
    receipt_file: StableFile
    dependency_files: tuple[StableFile, ...]
    run_root: Path
    derived_data_root: Path
    build_source_root: Path
    dependency_cache_root: Path
    source_commit: str
    source_tree: str
    inherited_dependency_lease: tuple = ()
    cache_release_inputs: dict | None = None


def _metadata(value: os.stat_result) -> tuple[int, int, int, int, int, int, int]:
    return (
        value.st_dev,
        value.st_ino,
        stat.S_IMODE(value.st_mode),
        value.st_nlink,
        value.st_size,
        value.st_mtime_ns,
        value.st_ctime_ns,
    )


def _stable_file(path: Path, *, maximum_bytes: int, label: str) -> StableFile:
    if not path.is_absolute():
        raise ProductIdentityError(f"{label} must be an absolute path")
    _ordinary_directory(path.parent, label=f"{label} parent")
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_CLOEXEC", 0)
    try:
        descriptor = os.open(path, flags)
    except OSError as error:
        raise ProductIdentityError(f"cannot safely open {label}: {path}: {error}") from error
    try:
        before = os.fstat(descriptor)
        if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1:
            raise ProductIdentityError(f"{label} must be an ordinary single-link file")
        if before.st_size > maximum_bytes:
            raise ProductIdentityError(f"{label} exceeds its size bound")
        chunks: list[bytes] = []
        observed_size = 0
        while True:
            block = os.read(descriptor, 1024 * 1024)
            if not block:
                break
            observed_size += len(block)
            if observed_size > maximum_bytes:
                raise ProductIdentityError(f"{label} exceeds its size bound")
            chunks.append(block)
        after = os.fstat(descriptor)
    except OSError as error:
        raise ProductIdentityError(f"cannot safely read {label}: {path}: {error}") from error
    finally:
        os.close(descriptor)
    if _metadata(before) != _metadata(after):
        raise ProductIdentityError(f"{label} changed while it was read")
    return StableFile(path=path, metadata=_metadata(before), payload=b"".join(chunks))


def _require_unchanged(snapshot: StableFile, *, label: str) -> None:
    observed = _stable_file(
        snapshot.path,
        maximum_bytes=max(len(snapshot.payload), 1),
        label=label,
    )
    if observed.metadata != snapshot.metadata or observed.payload != snapshot.payload:
        raise ProductIdentityError(f"{label} changed during validation")


def _canonical_line_bytes(value: object) -> bytes:
    return (
        json.dumps(
            value,
            ensure_ascii=True,
            allow_nan=False,
            sort_keys=True,
            separators=(",", ":"),
        )
        + "\n"
    ).encode("utf-8")


def _closed_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise ProductIdentityError(f"duplicate JSON object key: {key}")
        result[key] = value
    return result


def _reject_float(value: str) -> None:
    raise ProductIdentityError(f"floating-point JSON value is forbidden: {value}")


def _decode_canonical_line(payload: bytes, *, label: str) -> Any:
    try:
        text = payload.decode("utf-8")
        value = json.loads(
            text,
            object_pairs_hook=_closed_object,
            parse_float=_reject_float,
            parse_constant=_reject_float,
        )
    except UnicodeDecodeError as error:
        raise ProductIdentityError(f"{label} is not UTF-8") from error
    except json.JSONDecodeError as error:
        raise ProductIdentityError(f"{label} is malformed JSON: {error}") from error
    if _canonical_line_bytes(value) != payload:
        raise ProductIdentityError(f"{label} is not canonical line-delimited JSON")
    return value


def _sha256(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


def _require_sha256(value: object, *, label: str) -> str:
    if not isinstance(value, str) or SHA256_RE.fullmatch(value) is None:
        raise ProductIdentityError(f"{label} must be one lowercase SHA-256")
    return value


def _require_git(value: object, *, label: str) -> str:
    if not isinstance(value, str) or GIT_RE.fullmatch(value) is None:
        raise ProductIdentityError(f"{label} must be one lowercase 40-hex Git object")
    return value


def _parse_text_manifest(payload: bytes, *, label: str) -> dict[str, str]:
    try:
        text = payload.decode("utf-8")
    except UnicodeDecodeError as error:
        raise ProductIdentityError(f"{label} is not UTF-8") from error
    if not text.endswith("\n") or "\r" in text or "\0" in text:
        raise ProductIdentityError(f"{label} is not canonical text")
    values: dict[str, str] = {}
    for line in text[:-1].split("\n"):
        if line.count("=") != 1:
            raise ProductIdentityError(f"{label} is malformed")
        key, value = line.split("=", 1)
        if not key or not value or key in values:
            raise ProductIdentityError(f"{label} has an invalid field")
        values[key] = value
    return values


def _ordinary_directory(path: Path, *, label: str) -> Path:
    if not path.is_absolute():
        raise ProductIdentityError(f"{label} must be an absolute path")
    try:
        metadata = path.lstat()
        resolved = path.resolve(strict=True)
    except OSError as error:
        raise ProductIdentityError(f"{label} is unavailable: {path}: {error}") from error
    if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISDIR(metadata.st_mode):
        raise ProductIdentityError(f"{label} must be a non-symlink directory")
    if resolved != path:
        raise ProductIdentityError(f"{label} must be canonical and traverse no symbolic links")
    return resolved


def _assert_outside(path: Path, other: Path, *, label: str) -> None:
    if path == other or path in other.parents or other in path.parents:
        raise ProductIdentityError(f"{label} roots must not overlap")


def _require_contained_ordinary_path(
    root: Path, relative_path: str, *, directory: bool
) -> Path:
    current = root
    parts = Path(relative_path).parts
    if any(part in ("", ".", "..") for part in parts):
        if relative_path != ".":
            raise ProductIdentityError(f"unsafe product-relative path: {relative_path}")
        parts = ()
    _ordinary_directory(root, label="product root")
    for index, part in enumerate(parts):
        current = current / part
        is_final = index == len(parts) - 1
        if (not is_final) or directory:
            _ordinary_directory(current, label=f"product component {relative_path}")
        else:
            metadata = current.lstat()
            if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISREG(metadata.st_mode):
                raise ProductIdentityError(
                    f"required path is not a non-symlink regular file: {current}"
                )
    return current


def _bundle_identity(bundle: Path, executable_name: str) -> tuple[str, StableFile]:
    plist_path = _require_contained_ordinary_path(
        bundle, "Contents/Info.plist", directory=False
    )
    plist_snapshot = _stable_file(
        plist_path, maximum_bytes=MAX_PLIST_BYTES, label="product Info.plist"
    )
    try:
        document = plistlib.loads(plist_snapshot.payload)
    except plistlib.InvalidFileException as error:
        raise ProductIdentityError(f"cannot decode product Info.plist: {plist_path}") from error
    if not isinstance(document, dict):
        raise ProductIdentityError(f"product Info.plist is not a dictionary: {plist_path}")
    identifier = document.get("CFBundleIdentifier")
    if not isinstance(identifier, str) or not identifier:
        raise ProductIdentityError(f"product Info.plist has no bundle identifier: {plist_path}")
    if document.get("CFBundleExecutable") != executable_name:
        raise ProductIdentityError(
            f"product Info.plist does not name the expected executable: {executable_name}"
        )
    return identifier, plist_snapshot


def validate_products(
    candidate: CandidateIdentity,
    app_bundle: Path,
    product_ids: tuple[str, ...],
) -> tuple[str, ...]:
    if not product_ids or len(product_ids) != len(set(product_ids)):
        raise ProductIdentityError("product IDs must be a nonempty unique sequence")
    unknown = sorted(set(product_ids) - set(PRODUCT_LAYOUTS))
    if unknown:
        raise ProductIdentityError(f"unknown qualification product IDs: {', '.join(unknown)}")

    expected = {
        identity.identity_id: identity
        for identity in candidate.application.qualification_executables
    }
    snapshots: list[StableFile] = []
    verified: list[str] = []
    for product_id in product_ids:
        identity = expected.get(product_id)
        if identity is None:
            raise ProductIdentityError(
                f"candidate identity does not name qualification product: {product_id}"
            )
        layout = PRODUCT_LAYOUTS[product_id]
        bundle = _require_contained_ordinary_path(
            app_bundle, layout.bundle_relative_path, directory=True
        )
        executable = _require_contained_ordinary_path(
            bundle, layout.executable_relative_path, directory=False
        )
        executable_name = Path(layout.executable_relative_path).name
        observed_bundle_identifier, plist_snapshot = _bundle_identity(
            bundle, executable_name
        )
        snapshots.append(plist_snapshot)
        if observed_bundle_identifier != identity.bundle_identifier:
            raise ProductIdentityError(
                "qualification product bundle identifier mismatch: "
                f"{product_id}: expected {identity.bundle_identifier}, "
                f"observed {observed_bundle_identifier}"
            )
        executable_snapshot = _stable_file(
            executable,
            maximum_bytes=1024 * 1024 * 1024,
            label=f"qualification executable {product_id}",
        )
        snapshots.append(executable_snapshot)
        if executable_snapshot.metadata[2] & 0o111 == 0:
            raise ProductIdentityError(
                f"qualification executable is not executable: {executable}"
            )
        observed_sha256 = _sha256(executable_snapshot.payload)
        if observed_sha256 != identity.sha256:
            raise ProductIdentityError(
                "qualification product executable mismatch: "
                f"{product_id}: expected {identity.sha256}, observed {observed_sha256}"
            )
        verified.append(product_id)
    for snapshot in snapshots:
        _require_unchanged(snapshot, label="qualification product leaf")
    return tuple(verified)


def _validate_source_identity(
    source: object,
    *,
    expected_ref: str,
    expected_commit: str,
    expected_tree: str,
) -> dict[str, Any]:
    if not isinstance(source, dict) or set(source) != SOURCE_EXPORT_V2_FIELDS:
        raise ProductIdentityError(
            "qualification source identity does not satisfy the closed source-export schema"
        )
    if source.get("schema_version") != 2 or source.get("repository_clean") is not True:
        raise ProductIdentityError("qualification source identity is not a clean schema-v2 export")
    if (
        source.get("canonical_integration_ref") != expected_ref
        or source.get("canonical_integration_commit") != expected_commit
        or source.get("git_head_commit") != expected_commit
        or source.get("git_head_tree") != expected_tree
    ):
        raise ProductIdentityError(
            "qualification source identity is not the exact requested integration candidate"
        )
    _require_git(source.get("canonical_integration_commit"), label="integration commit")
    _require_git(source.get("git_head_commit"), label="source commit")
    _require_git(source.get("git_head_tree"), label="source tree")
    parents = source.get("git_parent_commits")
    if not isinstance(parents, list) or any(
        not isinstance(parent, str) or GIT_RE.fullmatch(parent) is None
        for parent in parents
    ):
        raise ProductIdentityError("qualification source parent identities are malformed")
    _require_sha256(source.get("source_files_sha256"), label="source file manifest")
    return source


def _validate_pattern_adapter_declaration(value,build_source_root):
    if (not isinstance(value,dict) or set(value)!={'root','accepted_producer_receipt','scope'}
            or value['scope']!='retained-pattern-adapter-input; producer evidence reused'
            or not isinstance(value['root'],str)):
        raise ProductIdentityError('retained pattern adapter declaration is malformed')
    root=Path(value['root'])
    if (not root.is_absolute() or root.resolve(strict=True)!=root or not root.is_dir()
            or root.stat().st_uid!=os.getuid()
            or any(token in str(root) for token in ('"','$','//','\\','\n','\r'))):
        raise ProductIdentityError('retained pattern adapter root is not canonical and owned')
    record=value['accepted_producer_receipt']
    if (not isinstance(record,dict) or set(record)!={'path','fields'}
            or not isinstance(record['path'],str) or not isinstance(record['fields'],list)
            or len(record['fields'])!=7 or any(type(v) is not int for v in record['fields'])):
        raise ProductIdentityError('retained pattern producer receipt binding is malformed')
    path=Path(record['path'])
    if not path.is_absolute() or path.resolve(strict=True)!=path:
        raise ProductIdentityError('retained pattern producer receipt path is indirect')
    before=path.lstat()
    fields=lambda item:[item.st_dev,item.st_ino,item.st_mode,item.st_nlink,item.st_size,item.st_mtime_ns,item.st_ctime_ns]
    if (before.st_uid!=os.getuid() or not stat.S_ISREG(before.st_mode)
            or before.st_nlink!=1 or fields(before)!=record['fields']):
        raise ProductIdentityError('retained pattern producer receipt binding changed')
    handoff=_stable_file(path,maximum_bytes=64*1024,label='retained pattern producer receipt')
    configuration=_stable_file(build_source_root/'MacScope/DependencyRoots.local.xcconfig',
        maximum_bytes=64*1024,label='retained dependency root configuration')
    try:
        lines=configuration.payload.decode('utf-8').splitlines()
    except UnicodeError as error:
        raise ProductIdentityError('retained dependency root configuration is not UTF-8') from error
    roots=[]
    for line in lines:
        key,separator,entry=line.partition('=')
        if separator and key.strip()=='MACSCOPE_PATTERN_ADAPTER_ROOT':roots.append(entry.strip())
    if roots!=[str(root)] or fields(path.lstat())!=record['fields']:
        raise ProductIdentityError('retained pattern root configuration or receipt changed')
    return handoff,configuration


def _validate_qualification_receipt_fields(receipt,cache_release,build_source_root):
    expected=QUALIFICATION_V4_FIELDS|({'cache_release_admission'} if cache_release else set())
    if cache_release and isinstance(receipt,dict) and 'retained_pattern_adapter' in receipt:
        expected=expected|{'retained_pattern_adapter'}
    if not isinstance(receipt,dict) or set(receipt)!=expected:
        raise ProductIdentityError('qualification receipt does not satisfy the closed v4 schema')
    if 'retained_pattern_adapter' in receipt:
        return _validate_pattern_adapter_declaration(receipt['retained_pattern_adapter'],build_source_root)
    return ()


def validate_qualification_inputs(arguments: argparse.Namespace) -> QualificationInputs:
    cache_release = os.environ.get("MACSCOPE_CACHE_RELEASE_ADMISSION", "")
    retained_release = os.environ.get("MACSCOPE_RETAINED_RELEASE_QUALIFICATION_INPUTS", "")
    if retained_release and (arguments.expected_mode != "release" or not os.environ.get("MACSCOPE_NATIVE_RELEASE_ADMISSION")):
        raise ProductIdentityError("dependency inheritance requires typed native Release admission")
    run_root = _ordinary_directory(arguments.run_root, label="qualification run root")
    if run_root in (Path("/"), Path.home().resolve()):
        raise ProductIdentityError("qualification run root is dangerously broad")
    derived_data_root = _ordinary_directory(
        arguments.derived_data_root, label="qualification DerivedData root"
    )
    build_source_root = _ordinary_directory(
        arguments.build_source_root, label="sealed build source root"
    )
    dependency_cache_root = _ordinary_directory(
        arguments.dependency_cache_root, label="dependency cache root"
    )
    if derived_data_root != run_root / "DerivedData":
        raise ProductIdentityError("DerivedData root is not the exact run-owned root")
    if build_source_root != run_root / "source":
        raise ProductIdentityError("sealed build source is not the exact run-owned export")
    _assert_outside(
        dependency_cache_root,
        build_source_root,
        label="dependency cache and sealed source",
    )
    _assert_outside(
        dependency_cache_root,
        run_root,
        label="dependency cache and qualification run",
    )
    receipt_path = arguments.receipt
    if receipt_path != run_root / "QUALIFICATION_INPUTS.json":
        raise ProductIdentityError("qualification receipt is not owned by the exact run")
    receipt_file = _stable_file(
        receipt_path,
        maximum_bytes=MAX_RECEIPT_BYTES,
        label="qualification receipt",
    )
    receipt = _decode_canonical_line(receipt_file.payload, label="qualification receipt")
    pattern_files=_validate_qualification_receipt_fields(receipt,bool(cache_release),build_source_root)
    if receipt.get("schema_version") != 4 or receipt.get("mode") != arguments.expected_mode:
        raise ProductIdentityError("qualification receipt schema or mode differs from the request")
    for field in ("dependency_network_allowed", "dependency_network_used"):
        if not isinstance(receipt.get(field), bool):
            raise ProductIdentityError(f"qualification receipt {field} must be Boolean")
    if receipt["dependency_network_used"] is not False:
        raise ProductIdentityError("ordinary qualification must not use dependency network access")
    if receipt["dependency_network_allowed"] is not arguments.dependency_network_authorized:
        raise ProductIdentityError("qualification dependency-network authority differs from the request")

    expected_paths = {
        "build_source_root": build_source_root,
        "dependency_cache_root": dependency_cache_root,
        "ghostty_source_dir": run_root / "dependencies/ghostty-vt-qualification",
        "ghostty_surface_source_dir": run_root
        / "dependencies/ghostty-surface/GhosttySurface",
        "ghostty_surface_artifact_root": run_root
        / "dependencies/ghostty-surface/GhosttySurface/macos/GhosttyKit.xcframework",
        "sleigh_materialization_root": run_root
        / "dependencies/sleigh-native-source/SleighNativeSource/materialization",
        "zig_executable": build_source_root / "ThirdParty/Zig/zig-0.16.0/zig",
    }
    for field, expected in expected_paths.items():
        value = receipt.get(field)
        if not isinstance(value, str) or Path(value) != expected:
            raise ProductIdentityError(
                f"qualification receipt {field} differs from the exact consumed path"
            )
        if field == "zig_executable":
            if retained_release or cache_release:
                _ordinary_directory(expected.parent, label="Zig executable parent")
                metadata = expected.lstat()
                if not stat.S_ISREG(metadata.st_mode) or metadata.st_nlink != 1:
                    raise ProductIdentityError("admitted Zig executable is not an ordinary single-link file")
            else:
                _stable_file(
                    expected,
                    maximum_bytes=MAX_ZIG_EXECUTABLE_BYTES,
                    label="Zig executable",
                )
            if not os.access(expected, os.X_OK):
                raise ProductIdentityError("recorded Zig executable is not executable")
        else:
            _ordinary_directory(expected, label=f"qualification receipt {field}")

    expected_commit = _require_git(
        arguments.expected_integration_commit, label="expected integration commit"
    )
    expected_tree = _require_git(
        arguments.expected_integration_tree, label="expected integration tree"
    )
    _validate_source_identity(
        receipt.get("source_identity"),
        expected_ref=arguments.expected_integration_ref,
        expected_commit=expected_commit,
        expected_tree=expected_tree,
    )

    inherited_dependency_lease = ()
    retained_release = os.environ.get("MACSCOPE_RETAINED_RELEASE_QUALIFICATION_INPUTS", "")
    cache_inputs = None
    if cache_release:
        if retained_release or arguments.expected_mode != "release":
            raise ProductIdentityError("cache input authority requires an exclusive Release transaction")
        from Scripts.qualification import cache_release_inputs as cache_admission
        try:
            cache_inputs, admitted_receipt = cache_admission.inputs(build_source_root)
            if admitted_receipt != receipt:
                raise ValueError("cache input receipt differs from the requested qualification")
            digests = cache_inputs['manifest_digests']
            if (set(digests) != {'ghostty_artifact_manifest_sha256', 'ghostty_surface_manifest_sha256',
                                 'sleigh_materialization_manifest_sha256'}
                    or any(receipt.get(field) != _require_sha256(digest, label=field)
                           for field, digest in digests.items())):
                raise ValueError("cache manifest identities differ from admitted inputs")
        except (ValueError, OSError, KeyError) as error:
            raise ProductIdentityError(str(error)) from error
        dependency_files = list(pattern_files)
    elif retained_release:
        if arguments.expected_mode != "release" or not os.environ.get("MACSCOPE_NATIVE_RELEASE_ADMISSION"):
            raise ProductIdentityError("dependency inheritance requires typed native Release admission")
        from Scripts.qualification.qualification_manifest_inheritance import admit_manifests, revalidate
        try:
            inherited, inherited_dependency_lease = admit_manifests(
                Path(retained_release), receipt, run_root / "DEPENDENCY_CACHE_EVENTS.json")
            if any(receipt.get(field) != digest for field, digest in inherited.items()):
                raise ValueError("current manifest identities differ from admitted inheritance")
            revalidate(inherited_dependency_lease)
        except (ValueError, OSError, KeyError) as error:
            raise ProductIdentityError(str(error)) from error
        dependency_files = []
    else:
        manifest_specs = (
            (
                Path(str(receipt["ghostty_source_dir"]))
                / "zig-out/lib/.macscope-ghostty-vt-manifest",
                "ghostty_artifact_manifest_sha256",
                "Ghostty VT manifest",
            ),
            (
                Path(str(receipt["ghostty_surface_source_dir"]))
                / "macos/.macscope-ghostty-surface-manifest",
                "ghostty_surface_manifest_sha256",
                "Ghostty surface manifest",
            ),
            (
                Path(str(receipt["sleigh_materialization_root"])) / "MATERIALIZATION.json",
                "sleigh_materialization_manifest_sha256",
                "SLEIGH materialization manifest",
            ),
        )
        dependency_files: list[StableFile] = []
        for path, digest_field, label in manifest_specs:
            snapshot = _stable_file(path, maximum_bytes=MAX_MANIFEST_BYTES, label=label)
            expected_digest = _require_sha256(receipt.get(digest_field), label=digest_field)
            if _sha256(snapshot.payload) != expected_digest:
                raise ProductIdentityError(f"{label} differs from the qualification receipt")
            dependency_files.append(snapshot)
        ghostty_vt_root = _ordinary_directory(
            run_root / "dependencies/ghostty-vt",
            label="consumed Ghostty VT work root",
        )
        consumed_vt_manifest = _stable_file(
            ghostty_vt_root / "artifacts/lib/.macscope-ghostty-vt-manifest",
            maximum_bytes=MAX_MANIFEST_BYTES,
            label="consumed Ghostty VT manifest",
        )
        if consumed_vt_manifest.payload != dependency_files[0].payload:
            raise ProductIdentityError(
                "consumed Ghostty VT manifest differs from the qualification receipt view"
            )
        vt_manifest = _parse_text_manifest(
            consumed_vt_manifest.payload, label="consumed Ghostty VT manifest"
        )
        if vt_manifest.get("schema") != "5":
            raise ProductIdentityError("consumed Ghostty VT manifest schema is unsupported")
        consumed_vt_link = ghostty_vt_root / "artifacts/lib/libghostty-vt.dylib"
        try:
            consumed_vt_dylib = consumed_vt_link.resolve(strict=True)
        except OSError as error:
            raise ProductIdentityError(
                f"cannot resolve consumed Ghostty VT dylib: {consumed_vt_link}: {error}"
            ) from error
        consumed_vt_lib_root = (ghostty_vt_root / "artifacts/lib").resolve(strict=True)
        if (
            consumed_vt_dylib.parent != consumed_vt_lib_root
            or consumed_vt_dylib.name != "libghostty-vt.0.1.0.dylib"
        ):
            raise ProductIdentityError(
                "consumed Ghostty VT dylib does not resolve to the governed versioned artifact"
            )
        vt_leaves = (
            (
                consumed_vt_dylib,
                "dylib_sha256",
                "consumed Ghostty VT dylib",
            ),
            (
                ghostty_vt_root / "artifacts/include/ghostty/vt.h",
                "umbrella_header_sha256",
                "consumed Ghostty VT umbrella header",
            ),
            (
                ghostty_vt_root / "artifacts/include/module.modulemap",
                "module_map_sha256",
                "consumed Ghostty VT module map",
            ),
        )
        consumed_vt_snapshots: list[StableFile] = []
        for path, digest_field, label in vt_leaves:
            snapshot = _stable_file(
                path, maximum_bytes=1024 * 1024 * 1024, label=label
            )
            if _sha256(snapshot.payload) != _require_sha256(
                vt_manifest.get(digest_field), label=digest_field
            ):
                raise ProductIdentityError(f"{label} differs from the consumed VT manifest")
            consumed_vt_snapshots.append(snapshot)
        qualification_vt_dylib = _stable_file(
            Path(str(receipt["ghostty_source_dir"]))
            / "zig-out/lib/libghostty-vt.dylib",
            maximum_bytes=1024 * 1024 * 1024,
            label="qualification Ghostty VT dylib",
        )
        if qualification_vt_dylib.payload != consumed_vt_snapshots[0].payload:
            raise ProductIdentityError(
                "consumed Ghostty VT dylib differs from the qualification receipt view"
            )
        dependency_files.extend(
            (consumed_vt_manifest, *consumed_vt_snapshots, qualification_vt_dylib)
        )
    source_provenance = _stable_file(
        build_source_root / "SOURCE_PROVENANCE.json",
        maximum_bytes=MAX_MANIFEST_BYTES,
        label="sealed source provenance",
    )
    source_provenance_document = _decode_canonical_line(
        source_provenance.payload, label="sealed source provenance"
    )
    if source_provenance_document != receipt.get("source_identity"):
        raise ProductIdentityError(
            "sealed source provenance differs from the qualification receipt"
        )
    source_files = _stable_file(
        build_source_root / "SOURCE_FILES.json",
        maximum_bytes=MAX_SOURCE_RECORD_BYTES,
        label="sealed source file manifest",
    )
    source_files_document = _decode_canonical_line(
        source_files.payload, label="sealed source file manifest"
    )
    if (
        not isinstance(source_files_document, dict)
        or set(source_files_document) not in (
            {"files", "schema_version"},
            {"files", "schema_version", "submodules"},
        )
        or source_files_document.get("schema_version") != 2
        or not isinstance(source_files_document.get("files"), list)
        or source_provenance_document.get("source_file_count")
        != len(source_files_document["files"])
        or (not (retained_release or cache_release) and _sha256(source_files.payload)
            != source_provenance_document.get("source_files_sha256"))
        or ((retained_release or cache_release) and max(source_files.metadata[-2:]) > receipt_file.metadata[-2])
    ):
        raise ProductIdentityError(
            "sealed source file manifest differs from its source provenance"
        )
    contract = source_provenance_document.get("dependency_contract")
    package = contract.get("source_export_package") if isinstance(contract, dict) else None
    has_submodules = "submodules" in source_files_document
    is_submodule_package = (
        isinstance(package, dict)
        and type(package.get("version")) is int
        and package["version"] == 5
    )
    if has_submodules != is_submodule_package:
        raise ProductIdentityError("sealed source submodule manifest requires export package v5")
    if has_submodules:
        # Reuse the exporter's bounded, closed-schema parser. The upstream
        # export verification remains responsible for the complete Git tree
        # proof; this transaction retains the exact manifest hash fence.
        from Scripts.source_export_provenance import (
            SourceExportError,
            validated_submodules,
        )

        try:
            validated_submodules(source_files_document)
        except SourceExportError as error:
            raise ProductIdentityError(f"sealed source submodule manifest is invalid: {error}") from error
    dependency_files.extend((source_provenance, source_files))
    for snapshot in (receipt_file, *dependency_files):
        if cache_release:
            if _metadata(snapshot.path.lstat()) != snapshot.metadata:
                raise ProductIdentityError('cache transaction declaration metadata changed')
        else:
            _require_unchanged(snapshot, label="qualification declaration")
    if inherited_dependency_lease:
        revalidate(inherited_dependency_lease)
    return QualificationInputs(
        receipt=receipt,
        receipt_file=receipt_file,
        dependency_files=tuple(dependency_files),
        run_root=run_root,
        derived_data_root=derived_data_root,
        build_source_root=build_source_root,
        dependency_cache_root=dependency_cache_root,
        source_commit=expected_commit,
        source_tree=expected_tree,
        inherited_dependency_lease=tuple(inherited_dependency_lease),
        cache_release_inputs=cache_inputs,
    )


def _parse_surface_manifest(payload: bytes) -> dict[str, str]:
    values = _parse_text_manifest(payload, label="Ghostty surface manifest")
    if values.get("schema") != "3":
        raise ProductIdentityError("Ghostty surface manifest schema is unsupported")
    for _, _, digest_field in STAGED_LEAVES:
        _require_sha256(values.get(digest_field), label=f"Ghostty {digest_field}")
    return values


def _discover_staged_root(derived_data_root: Path) -> Path:
    candidates: list[Path] = []
    for current, directory_names, file_names in os.walk(
        derived_data_root, topdown=True, followlinks=False
    ):
        current_path = Path(current)
        safe_directories: list[str] = []
        for name in directory_names:
            child = current_path / name
            try:
                metadata = child.lstat()
            except OSError:
                continue
            if stat.S_ISDIR(metadata.st_mode) and not stat.S_ISLNK(metadata.st_mode):
                safe_directories.append(name)
        directory_names[:] = safe_directories
        if current_path.name == "MacScopeGhosttySurface" and STAGED_DESCRIPTOR_NAME in file_names:
            candidates.append(current_path)
    if len(candidates) != 1:
        raise ProductIdentityError(
            "DerivedData must contain exactly one build-owned staged Ghostty surface"
        )
    root = _ordinary_directory(candidates[0], label="staged Ghostty surface root")
    relative = root.relative_to(derived_data_root)
    if relative.parts[:2] != ("Build", "Intermediates.noindex"):
        raise ProductIdentityError("staged Ghostty surface is outside Xcode intermediates")
    return root


def _validate_staged_surface(
    authority: QualificationInputs,
) -> tuple[Path, StableFile, dict[str, tuple[int, str]], str]:
    if authority.cache_release_inputs is not None:
        from Scripts.qualification import cache_release_inputs as cache_admission
        cache_admission.revalidate(authority.cache_release_inputs)
        phase = cache_admission.read(authority.run_root / 'CACHE_RELEASE_PHASE_surface_MacScopeApp.json')
        staged_root = _discover_staged_root(authority.derived_data_root)
        if (phase['root'] != str(staged_root)
                or cache_admission.snapshot(staged_root) != phase['snapshot']):
            raise ProductIdentityError('controlled cache surface staging changed')
        evidence = phase['evidence']
        descriptor = _stable_file(staged_root / STAGED_DESCRIPTOR_NAME,
                                  maximum_bytes=MAX_STAGED_DESCRIPTOR_BYTES,
                                  label='new cache surface descriptor')
        document = _decode_canonical_line(descriptor.payload, label='new cache surface descriptor')
        if (document.get('schema_version') != 1
                or document.get('source_manifest_sha256') != authority.receipt['ghostty_surface_manifest_sha256']
                or _sha256(descriptor.payload) != evidence['ghostty_surface_staged_descriptor_sha256']):
            raise ProductIdentityError('controlled cache surface descriptor differs')
        rows = {row['path']: row for row in authority.cache_release_inputs['entries']['ghostty-surface']['payload_records']}
        observed = {}
        expected_leaves = []
        for role, relative, _ in STAGED_LEAVES:
            row = rows['macos/GhosttyKit.xcframework/macos-arm64/' + relative]
            digest = _require_sha256(row['sha256'], label='accepted surface leaf')
            if evidence['ghostty_surface_' + role + '_sha256'] != digest:
                raise ProductIdentityError('cache surface evidence differs from accepted ENTRY')
            observed[relative] = (row['size'], digest)
            expected_leaves.append(dict(role=role, relative_path=relative, sha256=digest))
        if document.get('leaves') != expected_leaves:
            raise ProductIdentityError('cache descriptor leaf closure differs')
        observed[STAGED_DESCRIPTOR_NAME] = (len(descriptor.payload), _sha256(descriptor.payload))
        tree = hashlib.sha256()
        for relative, (size, digest) in sorted(observed.items(), key=lambda row: os.fsencode(row[0])):
            tree.update(f'{relative}\0{size}\0{digest}\0'.encode())
        if tree.hexdigest() != evidence['ghostty_surface_staged_tree_sha256']:
            raise ProductIdentityError('cache surface descriptor tree differs')
        return staged_root, descriptor, observed, tree.hexdigest()
    staged_root = _discover_staged_root(authority.derived_data_root)
    observed_paths: set[str] = set()
    observed_directories: set[str] = set()
    directory_metadata: dict[Path, tuple[int, int, int, int, int, int, int]] = {
        staged_root: _metadata(staged_root.lstat())
    }
    snapshots: dict[str, StableFile] = {}
    for current, directory_names, file_names in os.walk(
        staged_root, topdown=True, followlinks=False
    ):
        current_path = Path(current)
        for name in directory_names:
            child = current_path / name
            metadata = child.lstat()
            if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISDIR(metadata.st_mode):
                raise ProductIdentityError("staged Ghostty surface contains an unsafe directory")
            relative_directory = child.relative_to(staged_root).as_posix()
            observed_directories.add(relative_directory)
            directory_metadata[child] = _metadata(metadata)
        for name in file_names:
            path = current_path / name
            relative = path.relative_to(staged_root).as_posix()
            if relative in observed_paths:
                raise ProductIdentityError("staged Ghostty surface contains duplicate leaves")
            observed_paths.add(relative)
            snapshots[relative] = _stable_file(
                path,
                maximum_bytes=(
                    MAX_STAGED_DESCRIPTOR_BYTES
                    if relative == STAGED_DESCRIPTOR_NAME
                    else 1024 * 1024 * 1024
                ),
                label=f"staged Ghostty surface leaf {relative}",
            )
    expected_paths = {STAGED_DESCRIPTOR_NAME, *(path for _, path, _ in STAGED_LEAVES)}
    if observed_paths != expected_paths:
        raise ProductIdentityError(
            "staged Ghostty surface must contain exactly its descriptor, archive, header, and module map"
        )
    if observed_directories != {"Headers"}:
        raise ProductIdentityError(
            "staged Ghostty surface must contain exactly its Headers directory"
        )
    retained = bool(authority.inherited_dependency_lease)
    if retained:
        declaration = _decode_canonical_line(_stable_file(
            authority.run_root / 'ghostty-surface-admission.json', maximum_bytes=65536,
            label='retained surface leaf admission').payload, label='retained surface leaf admission')
        if (declaration.get('schema_version') != 1
                or declaration.get('source_root') != authority.receipt['ghostty_surface_source_dir']
                or declaration.get('manifest_sha256') != authority.receipt['ghostty_surface_manifest_sha256']):
            raise ProductIdentityError('retained surface admission differs')
        rows = declaration['leaves']
        if len(rows) != 3 or {r['path'] for r in rows} != {
                'macos-arm64/' + relative for _, relative, _ in STAGED_LEAVES}:
            raise ProductIdentityError('retained surface leaf closure differs')
        manifest = {field: next(r['sha256'] for r in rows if r['path'] == 'macos-arm64/' + relative)
                    for _, relative, field in STAGED_LEAVES}
        for field, digest in manifest.items():
            _require_sha256(digest, label='retained Ghostty ' + field)
        manifest_digest = authority.receipt['ghostty_surface_manifest_sha256']
    else:
        surface_manifest = authority.dependency_files[1]
        manifest = _parse_surface_manifest(surface_manifest.payload)
        manifest_digest = _sha256(surface_manifest.payload)
    descriptor_snapshot = snapshots[STAGED_DESCRIPTOR_NAME]
    descriptor = _decode_canonical_line(
        descriptor_snapshot.payload, label="staged Ghostty surface descriptor"
    )
    expected_leaves = [
        {
            "role": role,
            "relative_path": relative,
            "sha256": manifest[digest_field],
        }
        for role, relative, digest_field in STAGED_LEAVES
    ]
    if (
        not isinstance(descriptor, dict)
        or set(descriptor) != {"leaves", "schema_version", "source_manifest_sha256"}
        or descriptor.get("schema_version") != 1
        or descriptor.get("source_manifest_sha256") != manifest_digest
        or descriptor.get("leaves") != expected_leaves
    ):
        raise ProductIdentityError(
            "staged Ghostty surface descriptor does not bind the exact verified leaves"
        )
    observed: dict[str, tuple[int, str]] = {}
    for _, relative, digest_field in STAGED_LEAVES:
        snapshot = snapshots[relative]
        digest = _sha256(snapshot.payload)
        if digest != manifest[digest_field]:
            raise ProductIdentityError(
                f"staged Ghostty surface leaf differs from its source manifest: {relative}"
            )
        observed[relative] = (len(snapshot.payload), digest)
    observed[STAGED_DESCRIPTOR_NAME] = (
        len(descriptor_snapshot.payload),
        _sha256(descriptor_snapshot.payload),
    )
    tree = hashlib.sha256()
    for relative, (size, digest) in sorted(
        observed.items(), key=lambda item: os.fsencode(item[0])
    ):
        tree.update(relative.encode("utf-8"))
        tree.update(b"\0")
        tree.update(str(size).encode("ascii"))
        tree.update(b"\0")
        tree.update(digest.encode("ascii"))
        tree.update(b"\0")
    for snapshot in snapshots.values():
        if retained:
            if _metadata(snapshot.path.lstat()) != snapshot.metadata:
                raise ProductIdentityError('staged surface metadata changed')
        else:
            _require_unchanged(snapshot, label="staged Ghostty surface leaf")
    for directory, before in directory_metadata.items():
        if _metadata(directory.lstat()) != before:
            raise ProductIdentityError("staged Ghostty surface changed during validation")
    return staged_root, descriptor_snapshot, observed, tree.hexdigest()


def _discover_ghostty_vt_build_root(
    derived_data_root: Path, configuration: str
) -> Path:
    candidates: list[Path] = []
    intermediates = derived_data_root / "Build/Intermediates.noindex"
    for manifest in intermediates.glob(
        "**/MacScopeGhosttyVT/artifacts/lib/.macscope-ghostty-vt-manifest"
    ):
        root = manifest.parents[2]
        relative = root.relative_to(intermediates)
        if any(part == configuration or part.startswith(configuration + "-") for part in relative.parts):
            candidates.append(root)
    if len(candidates) != 1:
        raise ProductIdentityError(
            f"DerivedData must contain exactly one {configuration} Xcode-owned Ghostty VT build"
        )
    return _ordinary_directory(candidates[0], label="Xcode-owned Ghostty VT build root")


def _macho_without_code_signature(payload: bytes, *, label: str) -> bytes:
    if len(payload) < 32 or payload[:4] != b"\xcf\xfa\xed\xfe":
        raise ProductIdentityError(f"{label} is not a little-endian 64-bit Mach-O")
    normalized = bytearray(payload)
    ncmds = struct.unpack_from("<I", payload, 16)[0]
    offset = 32
    signature_offset: int | None = None
    for _ in range(ncmds):
        if offset + 8 > len(payload):
            raise ProductIdentityError(f"{label} has a truncated load-command table")
        command, size = struct.unpack_from("<II", payload, offset)
        if size < 8 or offset + size > len(payload):
            raise ProductIdentityError(f"{label} has an invalid load command")
        if command == 0x19 and size >= 72:
            segment_name = payload[offset + 8 : offset + 24].split(b"\0", 1)[0]
            if segment_name == b"__LINKEDIT":
                normalized[offset + 32 : offset + 40] = b"\0" * 8
                normalized[offset + 48 : offset + 56] = b"\0" * 8
        elif command == 0x1D and size >= 16:
            signature_offset = struct.unpack_from("<I", payload, offset + 8)[0]
            normalized[offset + 8 : offset + 16] = b"\0" * 8
        offset += size
    if signature_offset is not None:
        if signature_offset <= 0 or signature_offset > len(normalized):
            raise ProductIdentityError(f"{label} has an invalid code-signature range")
        del normalized[signature_offset:]
    return bytes(normalized)


def _xcode_ghostty_vt_dylib_path(xcode_root: Path) -> Path:
    library_root = _ordinary_directory(
        xcode_root / "artifacts/lib", label="Xcode Ghostty VT library directory"
    )
    consumer = library_root / "libghostty-vt.dylib"
    # Verified staging publishes ordinary consumer bytes under this name. The
    # direct Zig builder instead publishes one of two governed version aliases.
    # Never bypass an ordinary consumer in favor of an unrelated versioned file.
    try:
        before = consumer.lstat()
        if not stat.S_ISLNK(before.st_mode):
            return consumer
        target = os.readlink(consumer)
        if target == "libghostty-vt.0.dylib":
            major = library_root / target
            major_before = major.lstat()
            if not stat.S_ISLNK(major_before.st_mode) or os.readlink(major) != "libghostty-vt.0.1.0.dylib":
                raise ProductIdentityError("Xcode Ghostty VT major-version alias differs")
            if _metadata(major.lstat()) != _metadata(major_before):
                raise ProductIdentityError("Xcode Ghostty VT major-version alias changed")
        elif target != "libghostty-vt.0.1.0.dylib":
            raise ProductIdentityError("Xcode Ghostty VT consumer alias differs")
        if _metadata(consumer.lstat()) != _metadata(before):
            raise ProductIdentityError("Xcode Ghostty VT consumer alias changed")
    except OSError as error:
        raise ProductIdentityError(f"cannot inspect Xcode Ghostty VT consumer: {error}") from error
    # The selected leaf still goes through _stable_file's no-follow, single-link
    # checks; neither the aliases nor arbitrary targets are followed by open().
    return library_root / "libghostty-vt.0.1.0.dylib"


_VT_CONTINUATION = None


def _consume_vt_product_continuation(authority, app_bundle):
    """Reuse a completed VT comparison when a later check stopped the run."""
    global _VT_CONTINUATION
    location = os.environ.get('MACSCOPE_VT_PRODUCT_CONTINUATION')
    if not location:
        _VT_CONTINUATION = None
        return False
    if not authority.inherited_dependency_lease:
        raise ProductIdentityError('VT continuation requires inherited dependency authority')
    # This is a completed-check extension of the already admitted transaction,
    # never authority supplied solely by an environment-selected JSON file.
    native_leases = [item for item in authority.inherited_dependency_lease
                     if isinstance(item, dict) and 'native' in item and 'value' in item]
    if len(native_leases) != 1:
        raise ProductIdentityError('VT continuation requires one native admission authority')
    binding = native_leases[0]['value'].get('vt_product_continuation')
    if not isinstance(binding, dict) or set(binding) != {'receipt', 'failed_run_log'}:
        raise ProductIdentityError('VT continuation lacks completed-check admission binding')
    path = Path(location)
    before = path.lstat()
    raw_fields = lambda value: [value.st_dev, value.st_ino, value.st_mode,
                               value.st_nlink, value.st_size, value.st_mtime_ns,
                               value.st_ctime_ns]
    if binding['receipt'] != {'path': str(path), 'fields': raw_fields(before)}:
        raise ProductIdentityError('VT continuation receipt differs from admitted binding')
    if (path.resolve(strict=True) != path or before.st_uid != os.getuid()
            or before.st_mode & 0o222 or before.st_nlink != 1):
        raise ProductIdentityError('VT continuation must be immutable and owner controlled')
    document = _decode_canonical_line(_stable_file(path, maximum_bytes=65536,
                                                  label='VT continuation').payload,
                                      label='VT continuation')
    if (document.get('schema_version') != 1
            or document.get('scope') != 'passed-ghostty-vt-comparison-before-later-manifest-index-failure'
            or document.get('source_commit') != authority.source_commit
            or document.get('source_tree') != authority.source_tree
            or document.get('app_bundle') != str(app_bundle)):
        raise ProductIdentityError('VT continuation transaction differs')
    if document.get('failed_run_log') != binding['failed_run_log']:
        raise ProductIdentityError('VT continuation failure log differs from admitted binding')
    xcode = _discover_ghostty_vt_build_root(authority.derived_data_root, 'Release')
    source = authority.run_root / 'dependencies/ghostty-vt'
    expected = {str(root / relative) for root in (source, xcode) for relative in (
        'artifacts/lib/.macscope-ghostty-vt-manifest', 'artifacts/include/ghostty/vt.h',
        'artifacts/include/module.modulemap')}
    expected.update(map(str, (source / 'artifacts/lib/libghostty-vt.0.1.0.dylib',
                              _xcode_ghostty_vt_dylib_path(xcode),
                              app_bundle / 'Contents/Frameworks/libghostty-vt.dylib')))
    rows = document['products']
    if len(rows) != 9 or {r['path'] for r in rows} != expected:
        raise ProductIdentityError('VT continuation product closure differs')
    _VT_CONTINUATION = [(path, _metadata(before))] + [
        (Path(row['path']), (row['fields'][0], row['fields'][1], stat.S_IMODE(row['fields'][2]), *row['fields'][3:]))
        for row in [document['failed_run_log'], *rows]]
    _revalidate_vt_continuation()
    return True


def _revalidate_vt_continuation():
    for path, expected in _VT_CONTINUATION or ():
        if path.resolve(strict=True) != path or _metadata(path.lstat()) != expected:
            raise ProductIdentityError('passed VT product metadata changed')


def _validate_ghostty_vt_products(
    authority: QualificationInputs, app_bundle: Path, configuration: str
) -> tuple[StableFile, StableFile, StableFile]:
    if authority.cache_release_inputs is not None:
        if configuration != 'Release':
            raise ProductIdentityError('cache VT product admission requires Release')
        from Scripts.qualification import cache_release_inputs as cache_admission
        cache_admission.revalidate(authority.cache_release_inputs)
        phase = cache_admission.read(authority.run_root / 'CACHE_RELEASE_PHASE_vt_MacScopeApp.json')
        output = app_bundle / 'Contents/Frameworks/libghostty-vt.dylib'
        if (phase.get('scope') != cache_admission.SCOPE or phase.get('phase') != 'vt'
                or phase.get('source_commit') != authority.source_commit
                or len(phase.get('outputs', [])) != 1
                or phase['outputs'][0]['path'] != str(output)):
            raise ProductIdentityError('cache VT signing output is not the exact new app product')
        for row in phase['outputs']:
            cache_admission.protected(row)
        xcode_root = _discover_ghostty_vt_build_root(authority.derived_data_root, configuration)
        if (phase['build_root'] != str(xcode_root)
                or cache_admission.snapshot(xcode_root) != phase['build_snapshot']):
            raise ProductIdentityError('controlled VT staging changed after signing')
        return ()
    if _consume_vt_product_continuation(authority, app_bundle):
        return ()
    source_root = authority.run_root / "dependencies/ghostty-vt"
    xcode_root = _discover_ghostty_vt_build_root(authority.derived_data_root, configuration)
    leaves = (
        "artifacts/lib/.macscope-ghostty-vt-manifest",
        "artifacts/include/ghostty/vt.h",
        "artifacts/include/module.modulemap",
    )
    for relative in leaves:
        source = _stable_file(source_root / relative, maximum_bytes=1024 * 1024 * 1024, label=f"independent Ghostty VT {relative}")
        product = _stable_file(xcode_root / relative, maximum_bytes=1024 * 1024 * 1024, label=f"Xcode Ghostty VT {relative}")
        if source.payload != product.payload:
            raise ProductIdentityError(f"Xcode Ghostty VT product differs from the independent source build: {relative}")
    source_dylib = _stable_file(source_root / "artifacts/lib/libghostty-vt.0.1.0.dylib", maximum_bytes=1024 * 1024 * 1024, label="independent Ghostty VT dylib")
    xcode_dylib = _stable_file(_xcode_ghostty_vt_dylib_path(xcode_root), maximum_bytes=1024 * 1024 * 1024, label="Xcode Ghostty VT dylib")
    if source_dylib.payload != xcode_dylib.payload:
        raise ProductIdentityError("Xcode Ghostty VT dylib differs from the independent source build")
    bundled_dylib = _stable_file(app_bundle / "Contents/Frameworks/libghostty-vt.dylib", maximum_bytes=1024 * 1024 * 1024, label="bundled Ghostty VT dylib")
    if bundled_dylib.payload != xcode_dylib.payload and _macho_without_code_signature(
        bundled_dylib.payload, label="bundled Ghostty VT dylib"
    ) != _macho_without_code_signature(xcode_dylib.payload, label="Xcode Ghostty VT dylib"):
        raise ProductIdentityError("bundled Ghostty VT dylib differs from the Xcode-built artifact")
    return source_dylib, xcode_dylib, bundled_dylib


def _provenance_present(path: Path) -> bool:
    """Missing is distinct from unreadable or indirect provenance."""
    try:
        path.lstat()
    except FileNotFoundError:
        return False
    except OSError as error:
        raise ProductIdentityError(f"cannot inspect qualification build provenance: {error}") from error
    return True


def expected_build_configuration(mode: str, requested: str | None) -> str:
    """Return the app configuration a qualification mode may be validated as.

    release always validates its Release candidate. full-test validates the
    Release candidate unless the qualifier was told to skip it
    (--release-candidate skip, intermediate PR CI only), in which case the run
    has no Release product and the Debug test host is validated instead.
    Other modes build only Debug.
    """
    default = "Release" if mode in {"release", "full-test"} else "Debug"
    if requested is None or requested == default:
        return default
    if mode == "full-test" and requested == "Debug":
        return "Debug"
    raise ProductIdentityError(
        f"{mode} qualification cannot be validated as a {requested} build"
    )


def validate_qualification_build(arguments: argparse.Namespace) -> dict[str, str]:
    authority = validate_qualification_inputs(arguments)
    configuration = expected_build_configuration(
        arguments.expected_mode, getattr(arguments, "expected_configuration", None)
    )
    expected_app = authority.derived_data_root / "Build/Products" / configuration / "MacScope.app"
    if arguments.app_bundle != expected_app:
        raise ProductIdentityError("app bundle is not the exact run-owned Xcode product")
    app_bundle = _ordinary_directory(arguments.app_bundle, label="qualification app bundle")
    executable = _require_contained_ordinary_path(
        app_bundle, "Contents/MacOS/MacScope", directory=False
    )
    bundle_identifier, plist_snapshot = _bundle_identity(app_bundle, "MacScope")
    if bundle_identifier != "org.macscope.app":
        raise ProductIdentityError("qualification app bundle identifier is incorrect")
    executable_snapshot = _stable_file(
        executable,
        maximum_bytes=1024 * 1024 * 1024,
        label="qualification app executable",
    )
    if executable_snapshot.metadata[2] & 0o111 == 0:
        raise ProductIdentityError("qualification app executable is not executable")
    vt_snapshots = _validate_ghostty_vt_products(authority, app_bundle, configuration)
    staged_root, descriptor_snapshot, observed, staged_tree = _validate_staged_surface(
        authority
    )

    provenance_path = app_bundle / "Contents/Resources/MacScopeBuildProvenance.json"
    _require_contained_ordinary_path(app_bundle, "Contents/Resources", directory=True)
    # Debug may omit provenance or retain runtime-only metadata. The producer
    # can also bind verified Debug source identity without granting Release eligibility.
    provenance_snapshot = None
    provenance = None
    if configuration == "Release" or _provenance_present(provenance_path):
        provenance_snapshot = _stable_file(
            provenance_path, maximum_bytes=MAX_PROVENANCE_BYTES,
            label="qualification build provenance",
        )
        provenance = _decode_canonical_line(
            provenance_snapshot.payload, label="qualification build provenance"
        )
        if (not isinstance(provenance, dict)
            or provenance.get("schema_version") != 1
            or provenance.get("configuration") != configuration):
            raise ProductIdentityError("qualification build provenance has the wrong configuration")
    if configuration == "Release":
        receipt = authority.receipt
        sealed_ghostty_source = _ordinary_directory(
            authority.build_source_root / "ThirdParty/GhosttyVT/Source",
            label="sealed Release Ghostty source root",
        )
        expected_release = {
            "qualification_eligible": True,
            "repository_clean": True,
            "git_head_commit": authority.source_commit,
            "git_head_tree": authority.source_tree,
            "ghostty_source_dir_sha256": hashlib.sha256(
                os.fsencode(str(sealed_ghostty_source))
            ).hexdigest(),
            "sleigh_materialization_root_sha256": hashlib.sha256(
                os.fsencode(str(receipt["sleigh_materialization_root"]))
            ).hexdigest(),
            "ghostty_surface_source_manifest_sha256": receipt[
                "ghostty_surface_manifest_sha256"
            ],
            "ghostty_surface_staged_descriptor_relative_path": STAGED_DESCRIPTOR_NAME,
            "ghostty_surface_staged_descriptor_sha256": _sha256(
                descriptor_snapshot.payload
            ),
            "ghostty_surface_staged_tree_sha256": staged_tree,
            "sleigh_materialization_manifest_sha256": receipt[
                "sleigh_materialization_manifest_sha256"
            ],
            "ghostty_surface_compilation_condition": "MACSCOPE_FULL_GHOSTTY_SURFACE",
        }
        for field, expected in expected_release.items():
            if provenance.get(field) != expected:
                raise ProductIdentityError(
                    f"Release provenance {field} differs from the exact qualification transaction"
                )
        leaf_fields = {
            "libghostty-internal.a": "ghostty_surface_archive_sha256",
            "Headers/ghostty.h": "ghostty_surface_header_sha256",
            "Headers/module.modulemap": "ghostty_surface_module_map_sha256",
        }
        for relative, field in leaf_fields.items():
            if provenance.get(field) != observed[relative][1]:
                raise ProductIdentityError(
                    f"Release provenance {field} differs from the staged Ghostty surface"
                )
    elif provenance_snapshot is not None:
        if (provenance.get("qualification_eligible") is not False
            or provenance.get("repository_clean") is not False):
            raise ProductIdentityError("Debug provenance must remain Release-ineligible")
        debug_commit = provenance.get("git_head_commit")
        debug_tree = provenance.get("git_head_tree")
        # Legacy/runtime-only Debug metadata may lack both identities; the source
        # authority still comes from the separately validated qualification inputs.
        # A present identity must be the complete pair bound to that same authority.
        if (debug_commit is not None or debug_tree is not None) and (
            debug_commit != authority.source_commit or debug_tree != authority.source_tree
        ):
            raise ProductIdentityError(
                "Debug provenance source identity differs from the exact qualification transaction"
            )

    for snapshot, label in (
        (authority.receipt_file, "qualification receipt"),
        (plist_snapshot, "qualification app Info.plist"),
        (executable_snapshot, "qualification app executable"),
        (descriptor_snapshot, "staged Ghostty surface descriptor"),
        *([(provenance_snapshot, "qualification build provenance")] if provenance_snapshot is not None else []),
        *[(snapshot, "Ghostty VT build product") for snapshot in vt_snapshots],
    ):
        if authority.inherited_dependency_lease or authority.cache_release_inputs is not None:
            if _metadata(snapshot.path.lstat()) != snapshot.metadata:
                raise ProductIdentityError('retained validation file metadata changed')
        else:
            _require_unchanged(snapshot, label=label)
    for snapshot in authority.dependency_files:
        if authority.inherited_dependency_lease or authority.cache_release_inputs is not None:
            if _metadata(snapshot.path.lstat()) != snapshot.metadata:
                raise ProductIdentityError('inherited declaration metadata changed')
        else:
            _require_unchanged(snapshot, label="qualification dependency manifest")
    if authority.cache_release_inputs is not None:
        from Scripts.qualification import cache_release_inputs as cache_admission
        cache_admission.revalidate(authority.cache_release_inputs)
    _revalidate_vt_continuation()
    if provenance_snapshot is None and _provenance_present(provenance_path):
        raise ProductIdentityError("Debug provenance appeared during qualification validation")
    if authority.inherited_dependency_lease:
        from Scripts.qualification.qualification_manifest_inheritance import revalidate
        revalidate(authority.inherited_dependency_lease)
    return {
        "app_bundle": str(app_bundle),
        "app_executable_sha256": _sha256(executable_snapshot.payload),
        "derived_data_root": str(authority.derived_data_root),
        "ghostty_surface_staged_descriptor": str(descriptor_snapshot.path),
        "ghostty_surface_staged_root": str(staged_root),
        "source_commit": authority.source_commit,
        "source_tree": authority.source_tree,
    }


def _add_input_authority_arguments(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--receipt", type=Path, required=True)
    parser.add_argument("--run-root", type=Path, required=True)
    parser.add_argument("--derived-data-root", type=Path, required=True)
    parser.add_argument("--build-source-root", type=Path, required=True)
    parser.add_argument("--dependency-cache-root", type=Path, required=True)
    parser.add_argument(
        "--expected-mode",
        choices=("prepare", "smoke", "focused-test", "full-test", "release"),
        required=True,
    )
    parser.add_argument("--expected-integration-ref", required=True)
    parser.add_argument("--expected-integration-commit", required=True)
    parser.add_argument("--expected-integration-tree", required=True)
    parser.add_argument("--dependency-network-authorized", action="store_true")


def _parse_runner_arguments(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)
    inputs = subparsers.add_parser("validate-inputs")
    _add_input_authority_arguments(inputs)
    build = subparsers.add_parser("validate-build")
    _add_input_authority_arguments(build)
    build.add_argument("--app-bundle", type=Path, required=True)
    build.add_argument("--expected-configuration", choices=("Debug", "Release"))
    return parser.parse_args(argv)


def _parse_candidate_arguments(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--candidate-identity", type=Path, required=True)
    parser.add_argument("--app-bundle", type=Path, required=True)
    parser.add_argument(
        "--product",
        action="append",
        choices=tuple(PRODUCT_LAYOUTS),
        required=True,
    )
    parser.add_argument("--expected-candidate-sha256")
    parser.add_argument("--expected-source-commit")
    parser.add_argument("--expected-source-tree")
    return parser.parse_args(argv)


def parse_arguments(argv: list[str] | None = None) -> argparse.Namespace:
    values = list(sys.argv[1:] if argv is None else argv)
    if values and values[0] in {"validate-inputs", "validate-build"}:
        return _parse_runner_arguments(values)
    arguments = _parse_candidate_arguments(values)
    arguments.command = "validate-candidate-products"
    return arguments


def _load_candidate(arguments: argparse.Namespace) -> tuple[CandidateIdentity, StableFile]:
    candidate_file = _stable_file(
        arguments.candidate_identity,
        maximum_bytes=MAX_CANDIDATE_BYTES,
        label="candidate identity",
    )
    try:
        document = decode_canonical_bytes(candidate_file.payload)
    except CanonicalJSONError as error:
        raise ProductIdentityError(f"candidate identity is not canonical JSON: {error}") from error
    candidate, issues = parse_candidate_identity(document)
    if candidate is None or issues:
        diagnostics = "; ".join(
            f"{issue.code} at {issue.path}: {issue.message}" for issue in issues
        )
        raise ProductIdentityError(
            "candidate identity is invalid" + (f": {diagnostics}" if diagnostics else "")
        )
    expected_values = (
        arguments.expected_candidate_sha256,
        arguments.expected_source_commit,
        arguments.expected_source_tree,
    )
    if any(value is not None for value in expected_values) and not all(
        value is not None for value in expected_values
    ):
        raise ProductIdentityError(
            "expected candidate digest, source commit, and source tree must be supplied together"
        )
    if arguments.expected_candidate_sha256 is not None:
        expected_digest = _require_sha256(
            arguments.expected_candidate_sha256, label="expected candidate identity"
        )
        if candidate_identity_sha256(candidate) != expected_digest:
            raise ProductIdentityError("candidate identity differs from the transaction token")
        if candidate.source.commit != _require_git(
            arguments.expected_source_commit, label="expected candidate source commit"
        ):
            raise ProductIdentityError("candidate source commit differs from the transaction")
        if candidate.source.tree != _require_git(
            arguments.expected_source_tree, label="expected candidate source tree"
        ):
            raise ProductIdentityError("candidate source tree differs from the transaction")
    return candidate, candidate_file


def main(argv: list[str] | None = None) -> int:
    try:
        arguments = parse_arguments(argv)
        if arguments.command == "validate-inputs":
            authority = validate_qualification_inputs(arguments)
            print(f"MACSCOPE_QUALIFICATION_RUN_ROOT={authority.run_root}")
            print(f"MACSCOPE_QUALIFICATION_DERIVED_DATA_ROOT={authority.derived_data_root}")
            print(f"MACSCOPE_QUALIFICATION_SOURCE_COMMIT={authority.source_commit}")
            print(f"MACSCOPE_QUALIFICATION_SOURCE_TREE={authority.source_tree}")
            return 0
        if arguments.command == "validate-build":
            result = validate_qualification_build(arguments)
            print("verified qualification build transaction")
            for key, value in sorted(result.items()):
                print(f"MACSCOPE_QUALIFICATION_{key.upper()}={value}")
            return 0
        candidate, candidate_file = _load_candidate(arguments)
        verified = validate_products(
            candidate,
            arguments.app_bundle,
            tuple(arguments.product),
        )
        _require_unchanged(candidate_file, label="candidate identity")
    except (OSError, UnicodeError, ValueError, ProductIdentityError) as error:
        print(f"ERROR: qualification product identity validation failed: {error}", file=sys.stderr)
        return 1
    print("verified qualification products: " + ", ".join(verified))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
