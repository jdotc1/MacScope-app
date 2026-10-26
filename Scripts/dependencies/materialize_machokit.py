#!/usr/bin/env python3
"""Materialize the reviewed direct-source MachOKit dependency closure.

This is an explicit operator tool. It never acquires source from a network.
The MachOKit source archive and all three clean transitive Git checkouts must
already exist locally at their reviewed identities. Normal MacScope builds use
only a previously verified materialization.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import zipfile
from dataclasses import dataclass
from pathlib import Path, PurePosixPath
from typing import Iterable


SCHEMA_VERSION = 3
MAX_ARCHIVE_ENTRIES = 50_000
MAX_ARCHIVE_BYTES = 256 * 1024 * 1024
MAX_TREE_FILES = 75_000
MAX_FILE_BYTES = 64 * 1024 * 1024
MAX_TREE_BYTES = 384 * 1024 * 1024

MACHOKIT_VERSION = "0.52.2"
MACHOKIT_REVISION = "773e10797abc53914b94c2ee8c6f40f5da0b06eb"
MACHOKIT_ARCHIVE_SHA256 = "2e6d429f248ac3f01b896379c3c77518858a2213ef3da0d89939d112de9fd945"
MACHOKIT_UPSTREAM_TREE_SHA256 = "0a0bdc104b7f20c3f34ef595e113152cfc78ec496e96e14cb4957cf4d81dd038"
GOVERNED_SOURCE_IDENTITY = "b2f928cfc635b3a539129d1dbd50464c9d218c4a815553bc4b710ac813a790ea"
MATERIALIZATION_TREE_SHA256 = "e6796548485d32a183c3e1641989d637f5f6344c9e5af5a9cfbb83f549007950"
LOCAL_MANIFEST_PATCH = "ThirdParty/MachOKit/PATCHES.md"
OMITTED_MACHOKIT_SUBTREES = ("Benchmarks",)
REVIEWED_REMOTE_PACKAGE_DEPENDENCIES: frozenset[tuple[str, str]] = frozenset()
BUILD_IDENTITY_RELATIVE_PATH = (
    "MachOKit/Sources/MachOKit/MacScopeMachOKitBuildIdentity.swift"
)
BUILD_IDENTITY_PREFIX = "MACSCOPE_MACHOKIT_BUILD_ID"
GOVERNED_SOURCE_EXCLUSIONS = frozenset(
    {"MATERIALIZATION.json", BUILD_IDENTITY_RELATIVE_PATH}
)


@dataclass(frozen=True)
class Component:
    name: str
    repository: str
    revision: str
    git_tree: str
    materialized_tree_sha256: str


COMPONENTS = (
    Component(
        "swift-fileio",
        "https://github.com/p-x9/swift-fileio.git",
        "d589ff3966f9f064574780f527449a946736b989",
        "71314646e1831c21a9480f566396c6a77b7b6d32",
        "07d7a1b2821566423aee3677c7f1fc066621dcd0dbe4c9b608c092040a304da4",
    ),
    Component(
        "swift-fileio-extra",
        "https://github.com/p-x9/swift-fileio-extra.git",
        "8d83506dd4dff737807d90dbf2264096ed98c7a7",
        "95164a7178898951a246c4ce618de91989f8da7a",
        "3556201836c8410c92f069c8212e1429b83d37b165f8db9aa6e7289dca7f9c5b",
    ),
    Component(
        "swift-binary-parse-support",
        "https://github.com/p-x9/swift-binary-parse-support.git",
        "5fb96b503672ea4752eded6b4e301fd87214b03b",
        "5815e8dafb8899121841b11451502773a9a8fa96",
        "202d95c8aaca323d1f47db470e7a451a66f1d125711cd13c5a928da0f474eeb3",
    ),
)

EXPECTED_ROOT_ENTRIES = frozenset(
    {"MachOKit", "MATERIALIZATION.json", *(component.name for component in COMPONENTS)}
)

MACHOKIT_PACKAGE = r'''// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "MachOKit",
    platforms: [.macOS(.v10_15)],
    products: [
        .library(name: "MachOKit", targets: ["MachOKit"]),
    ],
    dependencies: [
        .package(path: "../swift-fileio"),
        .package(path: "../swift-fileio-extra"),
        .package(path: "../swift-binary-parse-support"),
    ],
    targets: [
        .target(
            name: "MachOKit",
            dependencies: [
                "MachOKitC",
                .product(name: "FileIO", package: "swift-fileio"),
                .product(name: "FileIOBinary", package: "swift-fileio-extra"),
                .product(name: "BinaryParseSupport", package: "swift-binary-parse-support"),
            ],
            swiftSettings: [
                .enableUpcomingFeature("ForwardTrailingClosures"),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("BareSlashRegexLiterals"),
                .enableUpcomingFeature("ConciseMagicFile"),
                .enableUpcomingFeature("ImportObjcForwardDeclarations"),
                .enableUpcomingFeature("DisableOutwardActorInference"),
                .enableUpcomingFeature("DeprecateApplicationMain"),
                .enableUpcomingFeature("IsolatedDefaultValues"),
                .enableUpcomingFeature("GlobalConcurrency"),
            ]
        ),
        .target(name: "MachOKitC", publicHeadersPath: "include"),
    ]
)
'''

FILEIO_EXTRA_PACKAGE = r'''// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "swift-fileio-extra",
    products: [
        .library(name: "FileIOBinary", targets: ["FileIOBinary"]),
    ],
    dependencies: [
        .package(path: "../swift-fileio"),
        .package(path: "../swift-binary-parse-support"),
    ],
    targets: [
        .target(
            name: "FileIOBinary",
            dependencies: [
                .product(name: "FileIO", package: "swift-fileio"),
                .product(name: "BinaryParseSupport", package: "swift-binary-parse-support"),
            ]
        ),
    ]
)
'''


class MaterializationError(RuntimeError):
    pass


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        while chunk := stream.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def _write_text(path: Path, text: str) -> None:
    """Write stable LF text using the repository's Python 3.9 runtime."""
    with path.open("w", encoding="utf-8", newline="\n") as stream:
        stream.write(text)


def _ordinary_files(root: Path) -> list[Path]:
    files: list[Path] = []
    total_bytes = 0
    for path in root.rglob("*"):
        relative = path.relative_to(root)
        lowered_parts = tuple(part.lower() for part in relative.parts)
        if any(part.endswith(".xcframework") for part in lowered_parts):
            raise MaterializationError(
                f"XCFramework content is prohibited by the direct-source contract: {relative}"
            )
        metadata = path.lstat()
        if stat.S_ISLNK(metadata.st_mode):
            raise MaterializationError(f"materialized tree contains a symbolic link: {relative}")
        if stat.S_ISDIR(metadata.st_mode):
            continue
        if not stat.S_ISREG(metadata.st_mode):
            raise MaterializationError(f"materialized tree contains a nonordinary file: {relative}")
        if metadata.st_nlink != 1:
            raise MaterializationError(
                f"materialized tree contains a multiply linked file: {relative}"
            )
        if metadata.st_size > MAX_FILE_BYTES:
            raise MaterializationError(f"materialized file exceeds the size bound: {relative}")
        total_bytes += metadata.st_size
        if total_bytes > MAX_TREE_BYTES:
            raise MaterializationError("materialized tree exceeds the total-byte bound")
        files.append(path)
        if len(files) > MAX_TREE_FILES:
            raise MaterializationError("materialized tree exceeds the file-count bound")
    return sorted(files, key=lambda item: os.fsencode(item.relative_to(root).as_posix()))


def _tree_digest(root: Path, *, excluded: frozenset[str] = frozenset()) -> str:
    digest = hashlib.sha256()
    for path in _ordinary_files(root):
        relative_text = path.relative_to(root).as_posix()
        if relative_text in excluded:
            continue
        relative = relative_text.encode("utf-8")
        payload = path.read_bytes()
        digest.update(len(relative).to_bytes(8, "big"))
        digest.update(relative)
        digest.update(len(payload).to_bytes(8, "big"))
        digest.update(payload)
    return digest.hexdigest()


def _governed_source_identity(root: Path) -> str:
    return _tree_digest(root, excluded=GOVERNED_SOURCE_EXCLUSIONS)


def _compiled_build_marker(governed_source_identity: str) -> str:
    return f"{BUILD_IDENTITY_PREFIX}:{MACHOKIT_REVISION}:{governed_source_identity}"


def _compiled_identity_source(governed_source_identity: str) -> str:
    marker = _compiled_build_marker(governed_source_identity)
    return (
        "// Generated deterministically by MacScope's reviewed MachOKit materializer.\n"
        "// Do not edit this file in a published materialization.\n\n"
        "public enum MacScopeMachOKitBuildIdentity {\n"
        f'    public static let marker = "{marker}"\n'
        "}\n"
    )


def _write_compiled_build_identity(root: Path) -> str:
    identity = _governed_source_identity(root)
    path = root / BUILD_IDENTITY_RELATIVE_PATH
    path.parent.mkdir(parents=True, exist_ok=True)
    _write_text(path, _compiled_identity_source(identity))
    return identity


def _verify_compiled_build_identity(
    root: Path,
    manifest: dict[str, object],
    *,
    enforce_reviewed_digest: bool,
) -> str:
    identity = _governed_source_identity(root)
    if manifest.get("governed_source_identity") != identity:
        raise MaterializationError("governed MachOKit source identity mismatch")
    if enforce_reviewed_digest and identity != GOVERNED_SOURCE_IDENTITY:
        raise MaterializationError("governed MachOKit source differs from reviewed input")
    marker = _compiled_build_marker(identity)
    if manifest.get("compiled_build_marker") != marker:
        raise MaterializationError("compiled MachOKit build marker receipt mismatch")
    path = root / BUILD_IDENTITY_RELATIVE_PATH
    if path.is_symlink() or not path.is_file():
        raise MaterializationError("compiled MachOKit build identity source is missing or unsafe")
    try:
        source = path.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as error:
        raise MaterializationError(
            f"compiled MachOKit build identity source is unreadable: {error}"
        ) from error
    if source != _compiled_identity_source(identity) or source.count(marker) != 1:
        raise MaterializationError("compiled MachOKit build identity source drifted")
    return identity


def _verify_read_only_shape(root: Path) -> None:
    for path in [root, *root.rglob("*")]:
        metadata = path.lstat()
        if metadata.st_mode & 0o222:
            relative = "." if path == root else path.relative_to(root).as_posix()
            raise MaterializationError(f"published materialization path is writable: {relative}")


def _freeze_tree(root: Path) -> None:
    files = _ordinary_files(root)
    directories: list[Path] = [root]
    for path in root.rglob("*"):
        metadata = path.lstat()
        if stat.S_ISDIR(metadata.st_mode):
            directories.append(path)
    for path in files:
        path.chmod(0o555 if path.stat().st_mode & 0o111 else 0o444)
    for path in sorted(directories, key=lambda item: len(item.parts), reverse=True):
        path.chmod(0o555)
    _verify_read_only_shape(root)


def _thaw_tree_for_cleanup(root: Path) -> None:
    """Best-effort recovery only when atomic publication itself fails."""
    for path in [root, *root.rglob("*")]:
        try:
            metadata = path.lstat()
            if stat.S_ISDIR(metadata.st_mode):
                path.chmod(metadata.st_mode | stat.S_IWUSR | stat.S_IXUSR)
            elif stat.S_ISREG(metadata.st_mode):
                path.chmod(metadata.st_mode | stat.S_IWUSR)
        except OSError:
            pass


def _safe_extract_zip(archive: Path, destination: Path) -> Path:
    if not archive.is_file() or archive.is_symlink():
        raise MaterializationError("MachOKit source archive must be an ordinary file")
    if archive.stat().st_size > MAX_ARCHIVE_BYTES:
        raise MaterializationError("MachOKit source archive exceeds the archive-size bound")
    total = 0
    roots: set[str] = set()
    names: set[str] = set()
    folded_names: set[str] = set()
    with zipfile.ZipFile(archive) as handle:
        infos = handle.infolist()
        if not 1 <= len(infos) <= MAX_ARCHIVE_ENTRIES:
            raise MaterializationError("MachOKit source archive has an invalid entry count")
        for info in infos:
            if "\\" in info.filename or "\x00" in info.filename:
                raise MaterializationError(f"unsafe archive path: {info.filename!r}")
            pure = PurePosixPath(info.filename)
            if pure.is_absolute() or not pure.parts or any(
                part in {"", ".", ".."} for part in pure.parts
            ):
                raise MaterializationError(f"unsafe archive path: {info.filename!r}")
            normalized = pure.as_posix().rstrip("/")
            folded = normalized.casefold()
            if normalized in names or folded in folded_names:
                raise MaterializationError(f"duplicate archive entry: {info.filename!r}")
            names.add(normalized)
            folded_names.add(folded)
            mode = info.external_attr >> 16
            if stat.S_ISLNK(mode):
                # The reviewed GitHub archive has one policy-file link. It is
                # not build input and must not become a link or copied payload.
                continue
            file_type = stat.S_IFMT(mode)
            if file_type and not stat.S_ISREG(mode) and not stat.S_ISDIR(mode):
                raise MaterializationError(f"archive contains a nonordinary entry: {info.filename!r}")
            if info.file_size > MAX_FILE_BYTES:
                raise MaterializationError(f"archive entry exceeds the size bound: {info.filename!r}")
            total += info.file_size
            if total > MAX_ARCHIVE_BYTES:
                raise MaterializationError("MachOKit source archive expands beyond the size bound")
            roots.add(pure.parts[0])
            target = destination.joinpath(*pure.parts)
            if info.is_dir():
                target.mkdir(parents=True, exist_ok=True)
                continue
            target.parent.mkdir(parents=True, exist_ok=True)
            with handle.open(info) as source, target.open("xb") as output:
                shutil.copyfileobj(source, output, length=1024 * 1024)
            target.chmod(0o755 if mode & 0o111 else 0o644)
    if len(roots) != 1:
        raise MaterializationError("MachOKit source archive must contain one top-level directory")
    root = destination / next(iter(roots))
    if root.is_symlink() or not root.is_dir():
        raise MaterializationError("MachOKit archive top-level entry is not a safe directory")
    _ordinary_files(root)
    return root


def _run(command: list[str], *, cwd: Path) -> str:
    environment = os.environ.copy()
    environment.update({"GIT_CONFIG_NOSYSTEM": "1", "GIT_TERMINAL_PROMPT": "0"})
    completed = subprocess.run(
        command,
        cwd=cwd,
        env=environment,
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    if completed.returncode != 0:
        raise MaterializationError(
            f"local identity command failed ({completed.returncode}): {' '.join(command)}"
            + (f"\n{completed.stderr.strip()}" if completed.stderr.strip() else "")
        )
    return completed.stdout.strip()


def _copy_local_component(source: Path, destination: Path, component: Component) -> str:
    source = source.expanduser().resolve(strict=True)
    if not (source / ".git").exists():
        raise MaterializationError(f"local source is not a Git checkout: {source}")
    revision = _run(["git", "rev-parse", "HEAD"], cwd=source)
    if revision != component.revision:
        raise MaterializationError(
            f"{component.name} revision mismatch: expected {component.revision}, found {revision}"
        )
    if _run(["git", "status", "--porcelain", "--untracked-files=all"], cwd=source):
        raise MaterializationError(f"{component.name} local source checkout is dirty")
    git_tree = _run(["git", "rev-parse", "HEAD^{tree}"], cwd=source)
    if git_tree != component.git_tree:
        raise MaterializationError(
            f"{component.name} Git tree mismatch: expected {component.git_tree}, found {git_tree}"
        )
    destination.mkdir()
    tracked = [item for item in _run(["git", "ls-files", "-z"], cwd=source).split("\0") if item]
    if not tracked:
        raise MaterializationError(f"{component.name} source checkout contains no tracked files")
    for item in tracked:
        pure = PurePosixPath(item)
        if pure.is_absolute() or any(part in {"", ".", ".."} for part in pure.parts):
            raise MaterializationError(f"{component.name} has an unsafe tracked path: {item!r}")
        source_path = source.joinpath(*pure.parts)
        metadata = source_path.lstat()
        if stat.S_ISLNK(metadata.st_mode):
            raise MaterializationError(f"{component.name} source contains a symbolic link: {item}")
        if not stat.S_ISREG(metadata.st_mode):
            raise MaterializationError(f"{component.name} source contains a nonordinary tracked path: {item}")
        if metadata.st_nlink != 1:
            raise MaterializationError(
                f"{component.name} source contains a multiply linked tracked file: {item}"
            )
        if metadata.st_size > MAX_FILE_BYTES:
            raise MaterializationError(f"{component.name} tracked file exceeds the size bound: {item}")
        destination_path = destination.joinpath(*pure.parts)
        destination_path.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source_path, destination_path)
        destination_path.chmod(metadata.st_mode & 0o111 | 0o644)
    _ordinary_files(destination)
    return git_tree


def _write_local_manifests(root: Path) -> None:
    _write_text(root / "MachOKit" / "Package.swift", MACHOKIT_PACKAGE)
    _write_text(root / "swift-fileio-extra" / "Package.swift", FILEIO_EXTRA_PACKAGE)
    for component in EXPECTED_ROOT_ENTRIES - {"MATERIALIZATION.json"}:
        path = root / component
        for removable in ("Package.resolved", ".swiftpm", ".build"):
            candidate = path / removable
            if candidate.is_dir() and not candidate.is_symlink():
                shutil.rmtree(candidate)
            elif candidate.exists() or candidate.is_symlink():
                candidate.unlink()
    _validate_admitted_source_shape(root)


def _omit_unadmitted_source_subtrees(root: Path) -> None:
    machokit = root / "MachOKit"
    for relative in OMITTED_MACHOKIT_SUBTREES:
        candidate = machokit / relative
        if not candidate.exists() and not candidate.is_symlink():
            continue
        if candidate.is_symlink() or not candidate.is_dir():
            raise MaterializationError(
                f"unadmitted MachOKit subtree is unsafe: MachOKit/{relative}"
            )
        shutil.rmtree(candidate)


def _validate_admitted_source_shape(root: Path) -> None:
    for relative in OMITTED_MACHOKIT_SUBTREES:
        candidate = root / "MachOKit" / relative
        if candidate.exists() or candidate.is_symlink():
            raise MaterializationError(
                f"unadmitted MachOKit subtree remains: MachOKit/{relative}"
            )
    for manifest in sorted(root.rglob("Package.swift")):
        relative = manifest.relative_to(root).as_posix()
        text = manifest.read_text(encoding="utf-8")
        for match in re.finditer(
            r"\.package\s*\(\s*url\s*:\s*[\"']([^\"']+)[\"']",
            text,
            flags=re.IGNORECASE,
        ):
            dependency = (relative, match.group(1))
            if dependency not in REVIEWED_REMOTE_PACKAGE_DEPENDENCIES:
                raise MaterializationError(
                    f"unreviewed URL package dependency remains in {relative}: {match.group(1)}"
                )
        if re.search(r"\.binaryTarget\s*\(", text, flags=re.IGNORECASE):
            raise MaterializationError(
                f"unreviewed binary package dependency remains in {relative}"
            )
        if re.search(r"\.xcframework(?:\b|[/\"'])", text, flags=re.IGNORECASE):
            raise MaterializationError(
                f"XCFramework package dependency remains in {relative}"
            )


def _canonical_manifest(root: Path, components: list[dict[str, str]]) -> dict[str, object]:
    governed_source_identity = _governed_source_identity(root)
    return {
        "schema_version": SCHEMA_VERSION,
        "integration_form": "direct-source",
        "provider": {
            "id": "p-x9/MachOKit",
            "version": MACHOKIT_VERSION,
            "revision": MACHOKIT_REVISION,
            "source_archive_sha256": MACHOKIT_ARCHIVE_SHA256,
            "upstream_tree_sha256": MACHOKIT_UPSTREAM_TREE_SHA256,
        },
        "local_manifest_patch": LOCAL_MANIFEST_PATCH,
        "components": components,
        "governed_source_identity": governed_source_identity,
        "compiled_build_marker": _compiled_build_marker(governed_source_identity),
        "tree_sha256": _tree_digest(root, excluded=frozenset({"MATERIALIZATION.json"})),
    }


def _read_manifest(root: Path) -> dict[str, object]:
    path = root / "MATERIALIZATION.json"
    if path.is_symlink() or not path.is_file() or path.stat().st_size > 1024 * 1024:
        raise MaterializationError("MATERIALIZATION.json is missing, unsafe, or oversized")
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise MaterializationError(f"invalid MATERIALIZATION.json: {error}") from error
    if not isinstance(payload, dict):
        raise MaterializationError("MATERIALIZATION.json must contain an object")
    return payload


def _verify_root(
    root: Path,
    *,
    quiet: bool = False,
    enforce_reviewed_digests: bool,
    enforce_read_only: bool = False,
) -> Path:
    root = root.expanduser().resolve(strict=True)
    if root.is_symlink() or not root.is_dir():
        raise MaterializationError("MachOKit materialization root is not a safe directory")
    observed_entries = {item.name for item in root.iterdir()}
    extra = sorted(observed_entries - EXPECTED_ROOT_ENTRIES)
    missing = sorted(EXPECTED_ROOT_ENTRIES - observed_entries)
    if extra:
        raise MaterializationError(f"unexpected root entry in MachOKit materialization: {extra[0]}")
    if missing:
        raise MaterializationError(f"missing root entry in MachOKit materialization: {missing[0]}")
    _ordinary_files(root)
    manifest = _read_manifest(root)
    expected_keys = {
        "schema_version",
        "integration_form",
        "provider",
        "local_manifest_patch",
        "components",
        "governed_source_identity",
        "compiled_build_marker",
        "tree_sha256",
    }
    if set(manifest) != expected_keys or manifest.get("schema_version") != SCHEMA_VERSION:
        raise MaterializationError("unsupported or malformed MachOKit materialization schema")
    if manifest.get("integration_form") != "direct-source":
        raise MaterializationError("MachOKit integration form must be direct-source")
    expected_provider = {
        "id": "p-x9/MachOKit",
        "version": MACHOKIT_VERSION,
        "revision": MACHOKIT_REVISION,
        "source_archive_sha256": MACHOKIT_ARCHIVE_SHA256,
        "upstream_tree_sha256": MACHOKIT_UPSTREAM_TREE_SHA256,
    }
    if manifest.get("provider") != expected_provider:
        raise MaterializationError("MachOKit provider identity does not match the reviewed contract")
    if manifest.get("local_manifest_patch") != LOCAL_MANIFEST_PATCH:
        raise MaterializationError("MachOKit local-manifest patch identity is incorrect")
    _verify_compiled_build_identity(
        root,
        manifest,
        enforce_reviewed_digest=enforce_reviewed_digests,
    )
    for name in EXPECTED_ROOT_ENTRIES - {"MATERIALIZATION.json"}:
        path = root / name
        if path.is_symlink() or not path.is_dir() or not (path / "Package.swift").is_file():
            raise MaterializationError(f"materialized component is missing or unsafe: {name}")
    components = manifest.get("components")
    if not isinstance(components, list) or len(components) != len(COMPONENTS):
        raise MaterializationError("materialized transitive component set is incomplete")
    expected_record_keys = {
        "name",
        "repository",
        "revision",
        "git_tree",
        "acquisition",
        "tree_sha256",
    }
    for expected, record in zip(COMPONENTS, components):
        if not isinstance(record, dict) or set(record) != expected_record_keys:
            raise MaterializationError("materialized transitive component record is malformed")
        if (
            record.get("name") != expected.name
            or record.get("repository") != expected.repository
            or record.get("revision") != expected.revision
            or record.get("acquisition") != "local-clean-git-checkout"
            or record.get("git_tree") != expected.git_tree
        ):
            raise MaterializationError(f"materialized identity mismatch: {expected.name}")
        actual_component_tree = _tree_digest(root / expected.name)
        if record.get("tree_sha256") != actual_component_tree:
            raise MaterializationError(f"materialized tree checksum mismatch: {expected.name}")
        if enforce_reviewed_digests and actual_component_tree != expected.materialized_tree_sha256:
            raise MaterializationError(
                f"materialized tree differs from reviewed output: {expected.name}"
            )
    _write_local_manifest_validation(root)
    actual = _tree_digest(root, excluded=frozenset({"MATERIALIZATION.json"}))
    if manifest.get("tree_sha256") != actual:
        raise MaterializationError("materialization tree checksum mismatch")
    if enforce_reviewed_digests and actual != MATERIALIZATION_TREE_SHA256:
        raise MaterializationError("materialization tree differs from the reviewed output")
    if enforce_read_only:
        _verify_read_only_shape(root)
    if not quiet:
        print(f"verified MachOKit {MACHOKIT_VERSION} direct-source materialization: {root}")
    return root


def verify_root(root: Path, *, quiet: bool = False) -> Path:
    return _verify_root(
        root,
        quiet=quiet,
        enforce_reviewed_digests=True,
        enforce_read_only=True,
    )


def _write_local_manifest_validation(root: Path) -> None:
    _validate_admitted_source_shape(root)


def materialize(arguments: argparse.Namespace) -> Path:
    output = arguments.output_root.expanduser().resolve(strict=False)
    if output.exists() or output.is_symlink():
        raise MaterializationError(f"destination already exists: {output}")
    sources = list(arguments.local_source or ())
    if len(sources) != len(COMPONENTS):
        raise MaterializationError(
            "provide exactly three --local-source paths in reviewed component order"
        )
    archive = arguments.machokit_archive.expanduser().resolve(strict=True)
    if not archive.is_file() or archive.is_symlink():
        raise MaterializationError("MachOKit archive must be an ordinary file")
    observed = _sha256(archive)
    if observed != MACHOKIT_ARCHIVE_SHA256:
        raise MaterializationError(
            f"MachOKit archive checksum mismatch: expected {MACHOKIT_ARCHIVE_SHA256}, found {observed}"
        )
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".machokit-materialization-", dir=output.parent) as temporary:
        temporary_root = Path(temporary)
        staged = temporary_root / "staged"
        extracted = temporary_root / "extracted"
        staged.mkdir(mode=0o700)
        extracted.mkdir(mode=0o700)
        upstream = _safe_extract_zip(archive, extracted)
        if _tree_digest(upstream) != MACHOKIT_UPSTREAM_TREE_SHA256:
            raise MaterializationError("MachOKit extracted source tree checksum mismatch")
        shutil.copytree(upstream, staged / "MachOKit", symlinks=False)
        _omit_unadmitted_source_subtrees(staged)
        records: list[dict[str, str]] = []
        for component, source in zip(COMPONENTS, sources):
            git_tree = _copy_local_component(source, staged / component.name, component)
            records.append(
                {
                    "name": component.name,
                    "repository": component.repository,
                    "revision": component.revision,
                    "git_tree": git_tree,
                    "acquisition": "local-clean-git-checkout",
                    "tree_sha256": "",
                }
            )
        _write_local_manifests(staged)
        governed_source_identity = _write_compiled_build_identity(staged)
        if governed_source_identity != GOVERNED_SOURCE_IDENTITY:
            raise MaterializationError("governed MachOKit source differs from reviewed input")
        for record in records:
            record["tree_sha256"] = _tree_digest(staged / record["name"])
        manifest = _canonical_manifest(staged, records)
        _write_text(
            staged / "MATERIALIZATION.json",
            json.dumps(manifest, indent=2, sort_keys=True) + "\n",
        )
        _verify_root(
            staged,
            quiet=True,
            enforce_reviewed_digests=True,
            enforce_read_only=False,
        )
        _freeze_tree(staged)
        # macOS requires the directory itself to remain owner-writable while it
        # is renamed out of the private staging directory. Every descendant is
        # already frozen; the published root is immediately frozen below.
        staged.chmod(0o755)
        try:
            staged.rename(output)
        except OSError:
            _thaw_tree_for_cleanup(staged)
            raise
        output.chmod(0o555)
    verify_root(output, quiet=True)
    if not quiet_value(arguments):
        print(f"MACSCOPE_MACHOKIT_MATERIALIZATION_ROOT={output}")
    return output


def quiet_value(arguments: argparse.Namespace) -> bool:
    return bool(getattr(arguments, "quiet", False))


def link_root(root: Path, macscope_directory: Path, *, quiet: bool = False) -> Path:
    root = verify_root(root, quiet=True).resolve(strict=True)
    macscope = macscope_directory.expanduser().resolve(strict=True)
    if macscope.name != "MacScope" or not (macscope / "project.yml").is_file():
        raise MaterializationError("--macscope-directory must identify the MacScope source directory")
    repository_root = macscope.parent
    if root == repository_root or repository_root in root.parents:
        raise MaterializationError("MachOKit materialization must remain outside the repository")
    link = macscope / "LocalPackages"
    if link.is_symlink():
        current = link.resolve(strict=False)
        if current == root:
            if not quiet:
                print(f"MacScope local package link already current: {link} -> {root}")
            return link
        # A dangling link (e.g. its old $TMPDIR work root was wiped by a
        # restart) or one naming another verified MachOKit view (an earlier
        # default work root) is replaced atomically; anything else is refused.
        replaceable = not current.exists()
        if not replaceable:
            try:
                verify_root(current, quiet=True)
                replaceable = True
            except Exception:
                replaceable = False
        if not replaceable:
            raise MaterializationError(
                f"MacScope local package link targets another root: {link} -> {current}"
            )
        staging = link.with_name(f".LocalPackages-relink-{os.getpid()}")
        if staging.is_symlink():
            staging.unlink()
        staging.symlink_to(root, target_is_directory=True)
        os.replace(staging, link)
        if not quiet:
            print(f"relinked MacScope local packages: {link} -> {root} (was {current})")
        return link
    if link.exists():
        raise MaterializationError(f"MacScope local package path is not a symlink: {link}")
    link.symlink_to(root, target_is_directory=True)
    if not quiet:
        print(f"linked MacScope local packages: {link} -> {root}")
    return link


def parse_arguments(argv: Iterable[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    materialize_parser = commands.add_parser("materialize")
    materialize_parser.add_argument("--output-root", type=Path, required=True)
    materialize_parser.add_argument("--machokit-archive", type=Path, required=True)
    materialize_parser.add_argument(
        "--local-source",
        type=Path,
        action="append",
        required=True,
        help=(
            "repeat exactly three times in this order: swift-fileio, "
            "swift-fileio-extra, swift-binary-parse-support"
        ),
    )
    materialize_parser.add_argument("--quiet", action="store_true")
    verify_parser = commands.add_parser("verify")
    verify_parser.add_argument("--materialization-root", type=Path, required=True)
    verify_parser.add_argument("--quiet", action="store_true")
    link_parser = commands.add_parser("link")
    link_parser.add_argument("--materialization-root", type=Path, required=True)
    link_parser.add_argument("--macscope-directory", type=Path, required=True)
    link_parser.add_argument("--quiet", action="store_true")
    return parser.parse_args(argv)


def main(argv: Iterable[str] | None = None) -> int:
    arguments = parse_arguments(argv)
    try:
        if arguments.command == "materialize":
            materialize(arguments)
        elif arguments.command == "verify":
            verify_root(arguments.materialization_root, quiet=arguments.quiet)
        elif arguments.command == "link":
            link_root(
                arguments.materialization_root,
                arguments.macscope_directory,
                quiet=arguments.quiet,
            )
        else:
            raise AssertionError(arguments.command)
    except (MaterializationError, OSError, subprocess.SubprocessError, zipfile.BadZipFile) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
