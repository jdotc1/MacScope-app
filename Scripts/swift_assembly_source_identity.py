#!/usr/bin/env python3
"""Independently verify the checked-in swift-assembly direct-source closure.

This verifier is intentionally offline and does not execute Git. Its immutable
source-identity checksum is an independent repository anchor for the exact
materialization produced by the explicit dependency tool.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import stat
import sys
from pathlib import Path
from typing import Iterable


SCHEMA_VERSION = 1
PROVIDER = "swiftbin/swift-assembly"
REVISION = "b6798dbd0081ec989d25b5a0676ab8cbd36bd9b1"
GIT_TREE = "69fde307d20e1e8c73261cffffbf5a11f526a94c"
LICENSE_SHA256 = "00511a028804276eb97fcc0cdba28ce973bcaf37cfa555d3cf934d9cec08f7cb"
NOTICE_SHA256 = "7e19a4270b35d340c997d4b260ebb4e11d473216774f9a45a70efdd9aba525a5"
PATCHES_SHA256 = "800128b4fb20340f92b02a71d3aefdd6fe3237581444b6853f9d19ab0a9127fd"
EXPECTED_SOURCE_IDENTITY_SHA256 = "063a49e06b080a9f3488b5ba4c4f496eabc7778e6dbe09ce91a3de25c30f4afa"
MAX_FILES = 32
MAX_FILE_BYTES = 2 * 1024 * 1024
MAX_TOTAL_BYTES = 4 * 1024 * 1024
EXPECTED_ROOT_ENTRIES = frozenset(
    {
        "Sources", "LICENSE", "NOTICE.md", "PATCHES.md",
        "SOURCE_IDENTITY.json", "MATERIALIZATION.json",
    }
)
EXPECTED_SWIFT_SOURCES = frozenset(
    {
        "Sources/ARM64/A64BitmaskImmediate.swift",
        "Sources/ARM64/A64Decoder.swift",
        "Sources/ARM64/A64Encoder.swift",
        "Sources/ARM64/A64FloatingPointEncoder.swift",
        "Sources/ARM64/A64Formatter.swift",
        "Sources/ARM64/A64InstructionFormats.swift",
        "Sources/ARM64/A64InstructionParser.swift",
        "Sources/ARM64/A64Model.swift",
        "Sources/ARM64/A64Support.swift",
        "Sources/ARM64/A64VectorEncoder.swift",
        "Sources/ARM64/ARM64Assembler.swift",
        "Sources/Core/AssemblerError.swift",
        "Sources/Core/Endianness.swift",
        "Sources/Core/ParsedInstruction.swift",
        "Sources/Core/SourceParser.swift",
    }
)


class SwiftAssemblySourceIdentityError(RuntimeError):
    pass


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        while chunk := stream.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def _ordinary_files(root: Path) -> list[Path]:
    files: list[Path] = []
    total_bytes = 0
    for path in root.rglob("*"):
        relative = path.relative_to(root)
        if any(part.lower().endswith(".xcframework") for part in relative.parts):
            raise SwiftAssemblySourceIdentityError(
                f"XCFramework content violates the direct-source contract: {relative}"
            )
        metadata = path.lstat()
        if stat.S_ISLNK(metadata.st_mode):
            raise SwiftAssemblySourceIdentityError(
                f"materialized tree contains a symbolic link: {relative}"
            )
        if stat.S_ISDIR(metadata.st_mode):
            continue
        if not stat.S_ISREG(metadata.st_mode):
            raise SwiftAssemblySourceIdentityError(
                f"materialized tree contains a nonordinary file: {relative}"
            )
        if metadata.st_size > MAX_FILE_BYTES:
            raise SwiftAssemblySourceIdentityError(
                f"materialized file exceeds the size bound: {relative}"
            )
        total_bytes += metadata.st_size
        if total_bytes > MAX_TOTAL_BYTES:
            raise SwiftAssemblySourceIdentityError(
                "materialized tree exceeds the total-byte bound"
            )
        files.append(path)
        if len(files) > MAX_FILES:
            raise SwiftAssemblySourceIdentityError(
                "materialized tree exceeds the file-count bound"
            )
    return sorted(files, key=lambda item: os.fsencode(item.relative_to(root).as_posix()))


def tree_digest(root: Path, *, excluded: frozenset[str] = frozenset()) -> str:
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


def _read_json(path: Path, label: str) -> dict[str, object]:
    if path.is_symlink() or not path.is_file() or path.stat().st_size > 1024 * 1024:
        raise SwiftAssemblySourceIdentityError(f"{label} is missing, unsafe, or oversized")
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise SwiftAssemblySourceIdentityError(f"invalid {label}: {error}") from error
    if not isinstance(payload, dict):
        raise SwiftAssemblySourceIdentityError(f"{label} must contain an object")
    return payload


def verify_root(root: Path, *, quiet: bool = False) -> Path:
    root = root.expanduser()
    if root.is_symlink():
        raise SwiftAssemblySourceIdentityError(
            "swift-assembly materialization root must not be a symbolic link"
        )
    root = root.resolve(strict=True)
    if not root.is_dir():
        raise SwiftAssemblySourceIdentityError(
            "swift-assembly materialization root is not a safe directory"
        )
    files = _ordinary_files(root)
    observed_entries = {item.name for item in root.iterdir()}
    extras = sorted(observed_entries - EXPECTED_ROOT_ENTRIES)
    missing = sorted(EXPECTED_ROOT_ENTRIES - observed_entries)
    if extras:
        raise SwiftAssemblySourceIdentityError(f"unexpected root entry: {extras[0]}")
    if missing:
        raise SwiftAssemblySourceIdentityError(f"missing root entry: {missing[0]}")

    source_entries = {
        path.relative_to(root).as_posix()
        for path in files
        if path.relative_to(root).parts[0] == "Sources"
    }
    extra_sources = sorted(source_entries - EXPECTED_SWIFT_SOURCES)
    missing_sources = sorted(EXPECTED_SWIFT_SOURCES - source_entries)
    if extra_sources:
        label = "unexpected Swift source" if extra_sources[0].endswith(".swift") else "unexpected source-tree entry"
        raise SwiftAssemblySourceIdentityError(f"{label}: {extra_sources[0]}")
    if missing_sources:
        raise SwiftAssemblySourceIdentityError(
            f"missing materialized source: {missing_sources[0]}"
        )

    identity_path = root / "SOURCE_IDENTITY.json"
    if _sha256(identity_path) != EXPECTED_SOURCE_IDENTITY_SHA256:
        raise SwiftAssemblySourceIdentityError("source identity checksum mismatch")
    identity = _read_json(identity_path, "SOURCE_IDENTITY.json")
    if (
        identity.get("schemaVersion") != SCHEMA_VERSION
        or identity.get("provider") != PROVIDER
        or identity.get("revision") != REVISION
        or identity.get("gitTree") != GIT_TREE
        or identity.get("integrationMode") != "direct-source"
    ):
        raise SwiftAssemblySourceIdentityError(
            "source identity does not match the reviewed contract"
        )
    records = identity.get("sourceFiles")
    if not isinstance(records, list) or len(records) != len(EXPECTED_SWIFT_SOURCES):
        raise SwiftAssemblySourceIdentityError("source identity closure is incomplete")
    expected_record_keys = {
        "upstreamPath", "vendorPath", "size", "gitBlobSHA1", "sha256"
    }
    observed_record_paths: set[str] = set()
    for record in records:
        if not isinstance(record, dict) or set(record) != expected_record_keys:
            raise SwiftAssemblySourceIdentityError("source identity record is malformed")
        vendor_path = record.get("vendorPath")
        if not isinstance(vendor_path, str) or vendor_path not in EXPECTED_SWIFT_SOURCES:
            raise SwiftAssemblySourceIdentityError("source identity path is unreviewed")
        if vendor_path in observed_record_paths:
            raise SwiftAssemblySourceIdentityError("source identity path is duplicated")
        observed_record_paths.add(vendor_path)
        path = root / vendor_path
        if record.get("size") != path.stat().st_size or record.get("sha256") != _sha256(path):
            raise SwiftAssemblySourceIdentityError(f"source checksum mismatch: {vendor_path}")
    if observed_record_paths != EXPECTED_SWIFT_SOURCES:
        raise SwiftAssemblySourceIdentityError("source identity closure is incomplete")

    if _sha256(root / "LICENSE") != LICENSE_SHA256:
        raise SwiftAssemblySourceIdentityError("materialized MIT license checksum mismatch")
    if _sha256(root / "NOTICE.md") != NOTICE_SHA256:
        raise SwiftAssemblySourceIdentityError("materialized notice checksum mismatch")
    if _sha256(root / "PATCHES.md") != PATCHES_SHA256:
        raise SwiftAssemblySourceIdentityError("patch-ledger checksum mismatch")

    manifest = _read_json(root / "MATERIALIZATION.json", "MATERIALIZATION.json")
    if set(manifest) != {
        "schemaVersion",
        "provider",
        "integrationMode",
        "sourceIdentityFile",
        "sourceIdentitySHA256",
        "swiftSourceCount",
        "materializedFileCount",
        "materializedByteCount",
        "treeSHA256",
    }:
        raise SwiftAssemblySourceIdentityError("materialization manifest is malformed")
    materialized_files = [
        path for path in files
        if path.relative_to(root).as_posix() != "MATERIALIZATION.json"
    ]
    expected_values = {
        "schemaVersion": SCHEMA_VERSION,
        "provider": PROVIDER,
        "integrationMode": "direct-source",
        "sourceIdentityFile": "SOURCE_IDENTITY.json",
        "sourceIdentitySHA256": EXPECTED_SOURCE_IDENTITY_SHA256,
        "swiftSourceCount": len(EXPECTED_SWIFT_SOURCES),
        "materializedFileCount": len(materialized_files),
        "materializedByteCount": sum(path.stat().st_size for path in materialized_files),
        "treeSHA256": tree_digest(root, excluded=frozenset({"MATERIALIZATION.json"})),
    }
    if manifest != expected_values:
        raise SwiftAssemblySourceIdentityError(
            "materialization manifest does not match the observed tree"
        )
    if not quiet:
        print(f"verified {PROVIDER} direct-source materialization: {root}")
    return root


def parse_arguments(argv: Iterable[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--materialization-root", type=Path, required=True)
    parser.add_argument("--quiet", action="store_true")
    return parser.parse_args(argv)


def main(argv: Iterable[str] | None = None) -> int:
    arguments = parse_arguments(argv)
    try:
        verify_root(arguments.materialization_root, quiet=arguments.quiet)
    except (SwiftAssemblySourceIdentityError, OSError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
