#!/usr/bin/env python3
"""Create and verify the exact official Zig toolchain and package-store identities.

The archive checksum anchors provenance, while the Git-stable closed-tree digest
anchors every ordinary file, executable mode, and nonempty directory after the
official archive's empty directories are normalized away. A matching version
string by itself is not accepted as toolchain identity.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
from pathlib import PurePosixPath
import stat
import subprocess
import sys
import tempfile
from typing import Optional, Sequence


RECEIPT_SCHEMA = "macscope.zig-toolchain-receipt"
RECEIPT_SCHEMA_VERSION = 2
TREE_ALGORITHM = "git-stable-nonempty-directories-v2"
RECEIPT_FIELDS = frozenset(
    {
        "archive_sha256",
        "directory_count",
        "executable_relative_path",
        "file_count",
        "root_basename",
        "schema",
        "schema_version",
        "toolchain_tree_sha256",
        "total_file_bytes",
        "tree_algorithm",
        "version",
    }
)
STABLE_FIELDS = (
    "st_dev",
    "st_ino",
    "st_mode",
    "st_nlink",
    "st_size",
    "st_mtime_ns",
    "st_ctime_ns",
)
HEX_DIGITS = frozenset("0123456789abcdef")
GHOSTTY_SOURCE_EXCLUDED_ROOTS = frozenset({".git", ".zig-cache", "zig-out", "zig-pkg"})
# A private build snapshot is source-only. Generated zig-out artifacts and the
# separately copied project-local package store are never cache authorities.
GHOSTTY_SOURCE_SNAPSHOT_EXCLUDED_ROOTS = frozenset({".git", ".zig-cache", "zig-out", "zig-pkg"})


def _is_finder_metadata(name: str) -> bool:
    return name == ".DS_Store" or name.startswith("._")


class ZigToolchainReceiptError(RuntimeError):
    """The materialized Zig toolchain or its receipt is not exact."""


class ZigPackageStoreError(RuntimeError):
    """The closed project-local Zig dependency store is not exact."""


class GhosttySourceError(RuntimeError):
    """The normalized Ghostty source tree is not an exact ordinary-leaf tree."""


def _stable_fields(metadata: os.stat_result) -> tuple[int, ...]:
    return tuple(getattr(metadata, field) for field in STABLE_FIELDS)


def _require_sha256(value: str, label: str) -> str:
    if len(value) != 64 or any(character not in HEX_DIGITS for character in value):
        raise ZigToolchainReceiptError(f"{label} must be a lowercase SHA-256 digest")
    return value


def _canonical_receipt_bytes(receipt: dict[str, object]) -> bytes:
    return (json.dumps(receipt, sort_keys=True, separators=(",", ":")) + "\n").encode()


def _root_descriptor(root: Path) -> tuple[Path, int]:
    try:
        unresolved = root.absolute()
        unresolved_metadata = unresolved.lstat()
        canonical = unresolved.resolve(strict=True)
        canonical_metadata = canonical.lstat()
    except OSError as error:
        raise ZigToolchainReceiptError(f"Zig toolchain root is inaccessible: {error}") from error
    if (
        stat.S_ISLNK(unresolved_metadata.st_mode)
        or not stat.S_ISDIR(unresolved_metadata.st_mode)
        or not stat.S_ISDIR(canonical_metadata.st_mode)
    ):
        raise ZigToolchainReceiptError("Zig toolchain root must be an ordinary directory")
    flags = (
        os.O_RDONLY
        | getattr(os, "O_DIRECTORY", 0)
        | getattr(os, "O_NOFOLLOW", 0)
        | getattr(os, "O_CLOEXEC", 0)
    )
    try:
        descriptor = os.open(canonical, flags)
    except OSError as error:
        raise ZigToolchainReceiptError(f"Zig toolchain root cannot be opened: {error}") from error
    opened = os.fstat(descriptor)
    if _stable_fields(opened) != _stable_fields(canonical_metadata):
        os.close(descriptor)
        raise ZigToolchainReceiptError("Zig toolchain root changed before traversal")
    return canonical, descriptor


def _tree_records(root_descriptor: int) -> tuple[tuple[str, str, int, int, str | None], ...]:
    records: list[tuple[str, str, int, int, str | None]] = []

    def visit(directory_descriptor: int, relative: PurePosixPath) -> None:
        directory_before = os.fstat(directory_descriptor)
        try:
            names = sorted(os.listdir(directory_descriptor), key=os.fsencode)
        except OSError as error:
            raise ZigToolchainReceiptError(
                f"Zig toolchain directory is inaccessible: {error}"
            ) from error
        if not names:
            raise ZigToolchainReceiptError("Zig toolchain contains an empty directory")
        for name in names:
            # Finder metadata is not consumed by Zig. Use the same metadata
            # classification as source/package handling; preserve ordinary-leaf
            # checks and identity records for every other entry.
            if _is_finder_metadata(name):
                continue
            if any(character in name for character in ("\n", "\r", "\x00")):
                raise ZigToolchainReceiptError("Zig toolchain contains an unsafe path")
            child_relative = relative / name
            try:
                before = os.stat(name, dir_fd=directory_descriptor, follow_symlinks=False)
            except OSError as error:
                raise ZigToolchainReceiptError(
                    f"Zig toolchain entry is inaccessible: {error}"
                ) from error
            if stat.S_ISLNK(before.st_mode):
                raise ZigToolchainReceiptError("Zig toolchain contains a symbolic link")
            expected = _stable_fields(before)
            mode = stat.S_IMODE(before.st_mode)
            if stat.S_ISDIR(before.st_mode):
                flags = (
                    os.O_RDONLY
                    | getattr(os, "O_DIRECTORY", 0)
                    | getattr(os, "O_NOFOLLOW", 0)
                    | getattr(os, "O_CLOEXEC", 0)
                )
                child_descriptor = -1
                try:
                    child_descriptor = os.open(name, flags, dir_fd=directory_descriptor)
                    if _stable_fields(os.fstat(child_descriptor)) != expected:
                        raise ZigToolchainReceiptError(
                            "Zig toolchain directory changed before traversal"
                        )
                    visit(child_descriptor, child_relative)
                    after_descriptor = os.fstat(child_descriptor)
                finally:
                    if child_descriptor >= 0:
                        os.close(child_descriptor)
                after_path = os.stat(name, dir_fd=directory_descriptor, follow_symlinks=False)
                if (
                    _stable_fields(after_descriptor) != expected
                    or _stable_fields(after_path) != expected
                ):
                    raise ZigToolchainReceiptError(
                        "Zig toolchain directory changed during traversal"
                    )
                records.append((child_relative.as_posix(), "directory", mode, 0, None))
                continue
            if not stat.S_ISREG(before.st_mode):
                raise ZigToolchainReceiptError(
                    "Zig toolchain contains a non-regular special file"
                )
            if before.st_nlink != 1:
                raise ZigToolchainReceiptError("Zig toolchain contains a hard-linked file")
            flags = (
                os.O_RDONLY
                | getattr(os, "O_NOFOLLOW", 0)
                | getattr(os, "O_CLOEXEC", 0)
            )
            file_descriptor = -1
            digest = hashlib.sha256()
            try:
                file_descriptor = os.open(name, flags, dir_fd=directory_descriptor)
                opened = os.fstat(file_descriptor)
                if _stable_fields(opened) != expected:
                    raise ZigToolchainReceiptError(
                        "Zig toolchain file changed before hashing"
                    )
                while True:
                    block = os.read(file_descriptor, 1024 * 1024)
                    if not block:
                        break
                    digest.update(block)
                after_descriptor = os.fstat(file_descriptor)
            finally:
                if file_descriptor >= 0:
                    os.close(file_descriptor)
            after_path = os.stat(name, dir_fd=directory_descriptor, follow_symlinks=False)
            if (
                _stable_fields(after_descriptor) != expected
                or _stable_fields(after_path) != expected
            ):
                raise ZigToolchainReceiptError("Zig toolchain file changed during hashing")
            records.append(
                (child_relative.as_posix(), "file", mode, before.st_size, digest.hexdigest())
            )
        if _stable_fields(os.fstat(directory_descriptor)) != _stable_fields(directory_before):
            raise ZigToolchainReceiptError("Zig toolchain directory changed during enumeration")

    visit(root_descriptor, PurePosixPath())
    return tuple(sorted(records, key=lambda record: os.fsencode(record[0])))


def closed_tree_identity(root: Path) -> dict[str, object]:
    canonical, descriptor = _root_descriptor(root)
    try:
        root_before = os.fstat(descriptor)
        records = _tree_records(descriptor)
        root_after = os.fstat(descriptor)
    finally:
        os.close(descriptor)
    if _stable_fields(root_before) != _stable_fields(root_after):
        raise ZigToolchainReceiptError("Zig toolchain root changed during traversal")
    digest = hashlib.sha256(b"MacScope Zig toolchain closed tree v1\0")
    file_count = 0
    directory_count = 0
    total_file_bytes = 0
    for relative, kind, mode, size, content_sha256 in records:
        encoded_path = relative.encode("utf-8", errors="strict")
        digest.update(len(encoded_path).to_bytes(8, "big"))
        digest.update(encoded_path)
        digest.update(b"d" if kind == "directory" else b"f")
        digest.update(mode.to_bytes(4, "big"))
        if kind == "directory":
            directory_count += 1
            continue
        file_count += 1
        total_file_bytes += size
        digest.update(size.to_bytes(8, "big"))
        digest.update(bytes.fromhex(content_sha256 or ""))
    return {
        "canonical_root": canonical,
        "directory_count": directory_count,
        "file_count": file_count,
        "toolchain_tree_sha256": digest.hexdigest(),
        "total_file_bytes": total_file_bytes,
    }


def package_store_identity(root: Path) -> dict[str, object]:
    """Hash a closed Zig --system package store using its stable path/content shape.

    This intentionally preserves the package-store digest algorithm used when the
    Ghostty dependency closure was frozen.  Shape checks make omissions fail
    closed: symbolic links, hard links, special entries, and empty directories
    are rejected. Finder metadata are excluded from the closure.
    """

    canonical, descriptor = _root_descriptor(root)
    file_count = 0
    total_file_bytes = 0
    # The frozen package-store identity predates descriptor-backed traversal.
    # It hashes ordinary file records in one global bytewise relative-path
    # order.  A pre-order traversal is not an equivalent ordering: a sibling
    # such as ``a.`` sorts before the descendant ``a/file`` when the complete
    # relative paths are compared, even though the directory ``a`` is visited
    # first.  Retain the descriptor/TOCTOU validation below, but spool each
    # validated payload so the aggregate can be assembled only after the
    # complete set of ordinary leaves is known and globally sorted.
    validated_leaves: list[tuple[bytes, int, int, str]] = []

    def visit(
        directory_descriptor: int,
        relative: PurePosixPath,
        payload_spool,
    ) -> bool:
        nonlocal file_count, total_file_bytes
        directory_before = os.fstat(directory_descriptor)
        names = sorted(os.listdir(directory_descriptor), key=os.fsencode)
        if not names:
            raise ZigPackageStoreError("Zig package store contains an empty directory")
        contains_file = False
        for name in names:
            if _is_finder_metadata(name):
                continue
            if any(character in name for character in ("\n", "\r", "\x00")):
                raise ZigPackageStoreError("Zig package store contains an unsafe path")
            child_relative = relative / name
            before = os.stat(name, dir_fd=directory_descriptor, follow_symlinks=False)
            expected = _stable_fields(before)
            if stat.S_ISLNK(before.st_mode):
                raise ZigPackageStoreError("Zig package store contains a symbolic link")
            if stat.S_ISDIR(before.st_mode):
                flags = (
                    os.O_RDONLY
                    | getattr(os, "O_DIRECTORY", 0)
                    | getattr(os, "O_NOFOLLOW", 0)
                    | getattr(os, "O_CLOEXEC", 0)
                )
                child_descriptor = os.open(name, flags, dir_fd=directory_descriptor)
                try:
                    if _stable_fields(os.fstat(child_descriptor)) != expected:
                        raise ZigPackageStoreError(
                            "Zig package store directory changed before traversal"
                        )
                    child_contains_file = visit(child_descriptor, child_relative, payload_spool)
                    after_descriptor = os.fstat(child_descriptor)
                finally:
                    os.close(child_descriptor)
                after_path = os.stat(
                    name, dir_fd=directory_descriptor, follow_symlinks=False
                )
                if (
                    _stable_fields(after_descriptor) != expected
                    or _stable_fields(after_path) != expected
                ):
                    raise ZigPackageStoreError(
                        "Zig package store directory changed during traversal"
                    )
                contains_file = contains_file or child_contains_file
                continue
            if not stat.S_ISREG(before.st_mode):
                raise ZigPackageStoreError(
                    "Zig package store contains a non-regular special file"
                )
            if before.st_nlink != 1:
                raise ZigPackageStoreError("Zig package store contains a hard-linked file")
            flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_CLOEXEC", 0)
            file_descriptor = os.open(name, flags, dir_fd=directory_descriptor)
            payload_offset = payload_spool.tell()
            payload_digest = hashlib.sha256()
            try:
                if _stable_fields(os.fstat(file_descriptor)) != expected:
                    raise ZigPackageStoreError(
                        "Zig package store file changed before hashing"
                    )
                encoded_path = child_relative.as_posix().encode("utf-8", errors="strict")
                while True:
                    block = os.read(file_descriptor, 1024 * 1024)
                    if not block:
                        break
                    payload_digest.update(block)
                    payload_spool.write(block)
                after_descriptor = os.fstat(file_descriptor)
            finally:
                os.close(file_descriptor)
            after_path = os.stat(name, dir_fd=directory_descriptor, follow_symlinks=False)
            if (
                _stable_fields(after_descriptor) != expected
                or _stable_fields(after_path) != expected
            ):
                raise ZigPackageStoreError("Zig package store file changed during hashing")
            file_count += 1
            total_file_bytes += before.st_size
            validated_leaves.append(
                (encoded_path, before.st_size, payload_offset, payload_digest.hexdigest())
            )
            contains_file = True
        if _stable_fields(os.fstat(directory_descriptor)) != _stable_fields(directory_before):
            raise ZigPackageStoreError("Zig package store directory changed during enumeration")
        return contains_file

    try:
        with tempfile.TemporaryFile(mode="w+b") as payload_spool:
            root_before = os.fstat(descriptor)
            has_file = visit(descriptor, PurePosixPath(), payload_spool)
            root_after = os.fstat(descriptor)
            if _stable_fields(root_before) != _stable_fields(root_after):
                raise ZigPackageStoreError("Zig package store root changed during traversal")
            if not has_file:
                raise ZigPackageStoreError("Zig package store is empty")

            aggregate = hashlib.sha256()
            for encoded_path, size, payload_offset, expected_digest in sorted(
                validated_leaves, key=lambda leaf: leaf[0]
            ):
                aggregate.update(len(encoded_path).to_bytes(8, "big"))
                aggregate.update(encoded_path)
                aggregate.update(size.to_bytes(8, "big"))
                payload_spool.seek(payload_offset)
                remaining = size
                spooled_digest = hashlib.sha256()
                while remaining:
                    block = payload_spool.read(min(1024 * 1024, remaining))
                    if not block:
                        raise ZigPackageStoreError(
                            "Zig package store payload spool ended before the validated file"
                        )
                    remaining -= len(block)
                    spooled_digest.update(block)
                    aggregate.update(block)
                if spooled_digest.hexdigest() != expected_digest:
                    raise ZigPackageStoreError(
                        "Zig package store payload spool changed after validation"
                    )
    finally:
        os.close(descriptor)

    return {
        "canonical_root": canonical,
        "file_count": file_count,
        "package_store_sha256": aggregate.hexdigest(),
        "total_file_bytes": total_file_bytes,
    }


def ghostty_source_identity(root: Path) -> dict[str, object]:
    """Return the descriptor-rooted identity of normalized Ghostty source.

    Build outputs are excluded only as top-level directory names. Every accepted
    source leaf and directory is otherwise represented, including its mode. The
    normalized source is deliberately stricter than an extracted Git checkout:
    Finder metadata are excluded; symlinks (including the upstream documentation
    alias), hard links, and special files are rejected.
    """

    canonical, descriptor = _root_descriptor(root)
    records: list[tuple[str, str, int, int, str | None]] = []
    # The frozen source pin commits only (path, byte length, bytes), globally
    # ordered by encoded relative path. Descriptor traversal is depth-first for
    # TOCTOU safety, which is not necessarily that global order. Spool each
    # already-validated leaf while it is read rather than reopening source files
    # after traversal, then hash the spooled leaves in the frozen order.
    leaf_records: list[tuple[str, int, int, str]] = []
    leaf_spool = tempfile.TemporaryFile()

    def visit(directory_descriptor: int, relative: PurePosixPath) -> None:
        directory_before = os.fstat(directory_descriptor)
        try:
            names = sorted(os.listdir(directory_descriptor), key=os.fsencode)
        except OSError as error:
            raise GhosttySourceError(
                f"Ghostty source directory is inaccessible: {error}"
            ) from error
        for name in names:
            if relative == PurePosixPath() and name in GHOSTTY_SOURCE_EXCLUDED_ROOTS:
                before = os.stat(name, dir_fd=directory_descriptor, follow_symlinks=False)
                if not stat.S_ISDIR(before.st_mode) or stat.S_ISLNK(before.st_mode):
                    raise GhosttySourceError(
                        f"excluded Ghostty build path must be an ordinary directory: {name}"
                    )
                continue
            if _is_finder_metadata(name):
                continue
            if any(character in name for character in ("\n", "\r", "\x00")):
                raise GhosttySourceError("Ghostty source contains an unsafe path")
            child_relative = relative / name
            try:
                before = os.stat(name, dir_fd=directory_descriptor, follow_symlinks=False)
            except OSError as error:
                raise GhosttySourceError(
                    f"Ghostty source entry is inaccessible: {error}"
                ) from error
            expected = _stable_fields(before)
            mode = stat.S_IMODE(before.st_mode)
            if stat.S_ISLNK(before.st_mode):
                raise GhosttySourceError("Ghostty source contains a symbolic link")
            if stat.S_ISDIR(before.st_mode):
                flags = (
                    os.O_RDONLY
                    | getattr(os, "O_DIRECTORY", 0)
                    | getattr(os, "O_NOFOLLOW", 0)
                    | getattr(os, "O_CLOEXEC", 0)
                )
                child_descriptor = os.open(name, flags, dir_fd=directory_descriptor)
                try:
                    if _stable_fields(os.fstat(child_descriptor)) != expected:
                        raise GhosttySourceError(
                            "Ghostty source directory changed before traversal"
                        )
                    visit(child_descriptor, child_relative)
                    after_descriptor = os.fstat(child_descriptor)
                finally:
                    os.close(child_descriptor)
                after_path = os.stat(
                    name, dir_fd=directory_descriptor, follow_symlinks=False
                )
                if (
                    _stable_fields(after_descriptor) != expected
                    or _stable_fields(after_path) != expected
                ):
                    raise GhosttySourceError(
                        "Ghostty source directory changed during traversal"
                    )
                records.append((child_relative.as_posix(), "directory", mode, 0, None))
                continue
            if not stat.S_ISREG(before.st_mode):
                raise GhosttySourceError("Ghostty source contains a special file")
            if before.st_nlink != 1:
                raise GhosttySourceError("Ghostty source contains a hard-linked file")
            flags = (
                os.O_RDONLY
                | getattr(os, "O_NOFOLLOW", 0)
                | getattr(os, "O_CLOEXEC", 0)
            )
            file_descriptor = os.open(name, flags, dir_fd=directory_descriptor)
            digest = hashlib.sha256()
            spool_offset = leaf_spool.tell()
            try:
                if _stable_fields(os.fstat(file_descriptor)) != expected:
                    raise GhosttySourceError(
                        "Ghostty source file changed before hashing"
                    )
                while True:
                    block = os.read(file_descriptor, 1024 * 1024)
                    if not block:
                        break
                    digest.update(block)
                    leaf_spool.write(block)
                after_descriptor = os.fstat(file_descriptor)
            finally:
                os.close(file_descriptor)
            after_path = os.stat(name, dir_fd=directory_descriptor, follow_symlinks=False)
            if (
                _stable_fields(after_descriptor) != expected
                or _stable_fields(after_path) != expected
            ):
                raise GhosttySourceError("Ghostty source file changed during hashing")
            records.append(
                (child_relative.as_posix(), "file", mode, before.st_size, digest.hexdigest())
            )
            leaf_records.append(
                (
                    child_relative.as_posix(),
                    before.st_size,
                    spool_offset,
                    digest.hexdigest(),
                )
            )
        if _stable_fields(os.fstat(directory_descriptor)) != _stable_fields(directory_before):
            raise GhosttySourceError(
                "Ghostty source directory changed during enumeration"
            )

    try:
        try:
            root_before = os.fstat(descriptor)
            visit(descriptor, PurePosixPath())
            root_after = os.fstat(descriptor)
        finally:
            os.close(descriptor)
        if _stable_fields(root_before) != _stable_fields(root_after):
            raise GhosttySourceError("Ghostty source root changed during traversal")

        # Keep the frozen source-pin encoding stable: it has always committed
        # normalized source leaves (path, length, bytes), rather than checkout
        # metadata. The copied spool is the exact content already guarded by
        # descriptor/TOCTOU checks, so global ordering does not reopen a source
        # path or relax the authority boundary.
        source_digest = hashlib.sha256()
        for relative, size, spool_offset, _content_sha256 in sorted(
            leaf_records, key=lambda record: os.fsencode(record[0])
        ):
            encoded_path = relative.encode("utf-8", errors="strict")
            source_digest.update(len(encoded_path).to_bytes(8, "big"))
            source_digest.update(encoded_path)
            source_digest.update(size.to_bytes(8, "big"))
            leaf_spool.seek(spool_offset)
            remaining = size
            while remaining:
                block = leaf_spool.read(min(1024 * 1024, remaining))
                if not block:
                    raise GhosttySourceError("Ghostty source spool is truncated")
                source_digest.update(block)
                remaining -= len(block)

        file_count = 0
        directory_count = 0
        total_file_bytes = 0
        for _relative, kind, _mode, size, _content_sha256 in records:
            if kind == "directory":
                directory_count += 1
                continue
            file_count += 1
            total_file_bytes += size
        return {
            "canonical_root": canonical,
            "directory_count": directory_count,
            "file_count": file_count,
            "source_tree_sha256": source_digest.hexdigest(),
            "total_file_bytes": total_file_bytes,
        }
    finally:
        leaf_spool.close()


def verify_ghostty_source(root: Path, expected_sha256: str) -> str:
    _require_sha256(expected_sha256, "expected Ghostty source-tree identity")
    observed = ghostty_source_identity(root)["source_tree_sha256"]
    if observed != expected_sha256:
        raise GhosttySourceError(
            "Ghostty source does not match the frozen normalized source closure"
        )
    return str(observed)


def _snapshot_error(kind: str, message: str) -> RuntimeError:
    if kind == "toolchain":
        return ZigToolchainReceiptError(message)
    if kind == "package-store":
        return ZigPackageStoreError(message)
    return GhosttySourceError(message)


def create_private_snapshot(
    kind: str,
    source: Path,
    destination: Path,
    expected_sha256: str,
) -> dict[str, object]:
    """Descriptor-copy one exact input tree into a new private sibling.

    The copied tree, rather than the caller-writable source, is the build input.
    Validation happens over the complete copy. A mutate/restore race therefore
    either leaves the exact expected bytes in the snapshot or fails its frozen
    digest; two observations of a mutable source are never treated as authority.
    """

    if kind not in {"toolchain", "package-store", "ghostty-source"}:
        raise ValueError(f"unsupported snapshot kind: {kind}")
    _require_sha256(expected_sha256, f"expected {kind} snapshot identity")
    source_canonical, source_descriptor = _root_descriptor(source)
    try:
        parent = destination.parent.resolve(strict=True)
    except OSError as error:
        os.close(source_descriptor)
        raise _snapshot_error(kind, f"snapshot parent is inaccessible: {error}")
    if destination.exists() or destination.is_symlink():
        os.close(source_descriptor)
        raise _snapshot_error(kind, "snapshot destination must not already exist")
    destination_path = parent / destination.name
    os.mkdir(destination_path, 0o700)
    destination_descriptor = os.open(
        destination_path,
        os.O_RDONLY
        | getattr(os, "O_DIRECTORY", 0)
        | getattr(os, "O_NOFOLLOW", 0)
        | getattr(os, "O_CLOEXEC", 0),
    )

    def copy_directory(
        source_directory: int,
        destination_directory: int,
        relative: PurePosixPath,
    ) -> None:
        source_before = os.fstat(source_directory)
        names = sorted(os.listdir(source_directory), key=os.fsencode)
        if kind == "package-store" and not names:
            raise ZigPackageStoreError("Zig package store contains an empty directory")
        for name in names:
            if (
                kind == "ghostty-source"
                and relative == PurePosixPath()
                and name in GHOSTTY_SOURCE_SNAPSHOT_EXCLUDED_ROOTS
            ):
                excluded = os.stat(
                    name, dir_fd=source_directory, follow_symlinks=False
                )
                if not stat.S_ISDIR(excluded.st_mode) or stat.S_ISLNK(excluded.st_mode):
                    raise GhosttySourceError(
                        f"excluded Ghostty build path must be an ordinary directory: {name}"
                    )
                continue
            if _is_finder_metadata(name):
                continue
            if any(character in name for character in ("\n", "\r", "\x00")):
                raise _snapshot_error(kind, f"{kind} contains an unsafe path")
            before = os.stat(name, dir_fd=source_directory, follow_symlinks=False)
            expected = _stable_fields(before)
            if stat.S_ISLNK(before.st_mode):
                raise _snapshot_error(kind, f"{kind} contains a symbolic link")
            mode = stat.S_IMODE(before.st_mode)
            if stat.S_ISDIR(before.st_mode):
                os.mkdir(name, mode=mode or 0o700, dir_fd=destination_directory)
                source_child = os.open(
                    name,
                    os.O_RDONLY
                    | getattr(os, "O_DIRECTORY", 0)
                    | getattr(os, "O_NOFOLLOW", 0)
                    | getattr(os, "O_CLOEXEC", 0),
                    dir_fd=source_directory,
                )
                destination_child = os.open(
                    name,
                    os.O_RDONLY
                    | getattr(os, "O_DIRECTORY", 0)
                    | getattr(os, "O_NOFOLLOW", 0)
                    | getattr(os, "O_CLOEXEC", 0),
                    dir_fd=destination_directory,
                )
                try:
                    if _stable_fields(os.fstat(source_child)) != expected:
                        raise _snapshot_error(
                            kind, f"{kind} directory changed before snapshot copy"
                        )
                    copy_directory(source_child, destination_child, relative / name)
                    after_descriptor = os.fstat(source_child)
                    os.fsync(destination_child)
                finally:
                    os.close(destination_child)
                    os.close(source_child)
                after_path = os.stat(
                    name, dir_fd=source_directory, follow_symlinks=False
                )
                if (
                    _stable_fields(after_descriptor) != expected
                    or _stable_fields(after_path) != expected
                ):
                    raise _snapshot_error(
                        kind, f"{kind} directory changed during snapshot copy"
                    )
                continue
            if not stat.S_ISREG(before.st_mode):
                raise _snapshot_error(kind, f"{kind} contains a special file")
            if before.st_nlink != 1:
                raise _snapshot_error(kind, f"{kind} contains a hard-linked file")
            source_file = os.open(
                name,
                os.O_RDONLY
                | getattr(os, "O_NOFOLLOW", 0)
                | getattr(os, "O_CLOEXEC", 0),
                dir_fd=source_directory,
            )
            destination_file = os.open(
                name,
                os.O_WRONLY
                | os.O_CREAT
                | os.O_EXCL
                | getattr(os, "O_NOFOLLOW", 0)
                | getattr(os, "O_CLOEXEC", 0),
                0o600,
                dir_fd=destination_directory,
            )
            try:
                if _stable_fields(os.fstat(source_file)) != expected:
                    raise _snapshot_error(
                        kind, f"{kind} file changed before snapshot copy"
                    )
                while True:
                    block = os.read(source_file, 1024 * 1024)
                    if not block:
                        break
                    offset = 0
                    while offset < len(block):
                        offset += os.write(destination_file, block[offset:])
                os.fchmod(destination_file, mode)
                os.fsync(destination_file)
                after_descriptor = os.fstat(source_file)
            finally:
                os.close(destination_file)
                os.close(source_file)
            after_path = os.stat(
                name, dir_fd=source_directory, follow_symlinks=False
            )
            if (
                _stable_fields(after_descriptor) != expected
                or _stable_fields(after_path) != expected
            ):
                raise _snapshot_error(kind, f"{kind} file changed during snapshot copy")
        if _stable_fields(os.fstat(source_directory)) != _stable_fields(source_before):
            raise _snapshot_error(kind, f"{kind} directory changed during snapshot copy")

    try:
        copy_directory(source_descriptor, destination_descriptor, PurePosixPath())
        os.fsync(destination_descriptor)
    except Exception:
        os.close(destination_descriptor)
        os.close(source_descriptor)
        raise
    os.close(destination_descriptor)
    os.close(source_descriptor)

    if kind == "toolchain":
        identity = closed_tree_identity(destination_path)
        observed = str(identity["toolchain_tree_sha256"])
    elif kind == "package-store":
        identity = package_store_identity(destination_path)
        observed = str(identity["package_store_sha256"])
    else:
        identity = ghostty_source_identity(destination_path)
        observed = str(identity["source_tree_sha256"])
    if observed != expected_sha256:
        raise _snapshot_error(kind, f"{kind} snapshot does not match the frozen identity")
    identity["canonical_root"] = str(identity["canonical_root"])
    identity["snapshot_kind"] = kind
    identity["source_root"] = str(source_canonical)
    return identity


def verify_package_store(root: Path, expected_sha256: str) -> str:
    _require_sha256(expected_sha256, "expected Zig package-store identity")
    observed = package_store_identity(root)["package_store_sha256"]
    if observed != expected_sha256:
        raise ZigPackageStoreError(
            "Zig package store does not match the frozen dependency closure"
        )
    return str(observed)


def _observed_zig_version(root: Path) -> str:
    executable = root / "zig"
    try:
        metadata = executable.lstat()
    except OSError as error:
        raise ZigToolchainReceiptError(f"Zig executable is inaccessible: {error}") from error
    if (
        stat.S_ISLNK(metadata.st_mode)
        or not stat.S_ISREG(metadata.st_mode)
        or metadata.st_nlink != 1
        or stat.S_IMODE(metadata.st_mode) & 0o111 == 0
    ):
        raise ZigToolchainReceiptError("Zig executable must be an ordinary executable file")
    try:
        result = subprocess.run(
            [str(executable), "version"],
            capture_output=True,
            text=True,
            timeout=15,
            check=False,
            env={"LC_ALL": "C", "PATH": "/usr/bin:/bin"},
        )
    except (OSError, subprocess.SubprocessError) as error:
        raise ZigToolchainReceiptError(f"Zig version check failed: {error}") from error
    if result.returncode != 0:
        raise ZigToolchainReceiptError("Zig version check failed")
    return result.stdout.strip()


def _receipt_for(
    root: Path,
    expected_version: str,
    expected_archive_sha256: str,
    expected_tree_sha256: str,
) -> dict[str, object]:
    _require_sha256(expected_archive_sha256, "expected Zig archive identity")
    _require_sha256(expected_tree_sha256, "expected Zig closed-tree identity")
    identity = closed_tree_identity(root)
    canonical_root = identity.pop("canonical_root")
    if canonical_root.name != f"zig-{expected_version}":
        raise ZigToolchainReceiptError(
            f"Zig toolchain root must be named zig-{expected_version}"
        )
    observed_version = _observed_zig_version(canonical_root)
    if observed_version != expected_version:
        raise ZigToolchainReceiptError(
            f"Zig version mismatch: expected {expected_version}, found {observed_version}"
        )
    observed_tree = identity["toolchain_tree_sha256"]
    if observed_tree != expected_tree_sha256:
        raise ZigToolchainReceiptError(
            "Zig toolchain closed tree does not match the official materialization"
        )
    return {
        "archive_sha256": expected_archive_sha256,
        "directory_count": identity["directory_count"],
        "executable_relative_path": "zig",
        "file_count": identity["file_count"],
        "root_basename": canonical_root.name,
        "schema": RECEIPT_SCHEMA,
        "schema_version": RECEIPT_SCHEMA_VERSION,
        "toolchain_tree_sha256": observed_tree,
        "total_file_bytes": identity["total_file_bytes"],
        "tree_algorithm": TREE_ALGORITHM,
        "version": observed_version,
    }


def write_receipt(
    root: Path,
    receipt_path: Path,
    expected_version: str,
    expected_archive_sha256: str,
    expected_tree_sha256: str,
) -> str:
    receipt = _receipt_for(
        root, expected_version, expected_archive_sha256, expected_tree_sha256
    )
    payload = _canonical_receipt_bytes(receipt)
    receipt_parent = receipt_path.parent.resolve(strict=True)
    receipt_path = receipt_parent / receipt_path.name
    canonical_root = root.resolve(strict=True)
    if receipt_parent == canonical_root or canonical_root in receipt_parent.parents:
        raise ZigToolchainReceiptError("Zig receipt must live outside the toolchain root")
    temporary_path: Optional[Path] = None
    descriptor = -1
    try:
        descriptor, temporary_name = tempfile.mkstemp(
            prefix=f".{receipt_path.name}.", dir=receipt_parent
        )
        temporary_path = Path(temporary_name)
        os.fchmod(descriptor, 0o600)
        written = 0
        while written < len(payload):
            written += os.write(descriptor, payload[written:])
        os.fsync(descriptor)
        os.close(descriptor)
        descriptor = -1
        os.replace(temporary_path, receipt_path)
        temporary_path = None
    finally:
        if descriptor >= 0:
            os.close(descriptor)
        if temporary_path is not None:
            temporary_path.unlink(missing_ok=True)
    return hashlib.sha256(payload).hexdigest()


def _read_receipt(receipt_path: Path) -> bytes:
    try:
        before = receipt_path.lstat()
    except OSError as error:
        raise ZigToolchainReceiptError(f"Zig receipt is inaccessible: {error}") from error
    if (
        stat.S_ISLNK(before.st_mode)
        or not stat.S_ISREG(before.st_mode)
        or before.st_nlink != 1
        or before.st_size > 4096
    ):
        raise ZigToolchainReceiptError("Zig receipt must be a bounded ordinary file")
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_CLOEXEC", 0)
    descriptor = os.open(receipt_path, flags)
    try:
        opened = os.fstat(descriptor)
        chunks: list[bytes] = []
        total = 0
        while total <= 4096:
            chunk = os.read(descriptor, min(4097 - total, 1024))
            if not chunk:
                break
            chunks.append(chunk)
            total += len(chunk)
        payload = b"".join(chunks)
        after_descriptor = os.fstat(descriptor)
    finally:
        os.close(descriptor)
    after_path = receipt_path.lstat()
    if (
        _stable_fields(before) != _stable_fields(opened)
        or _stable_fields(before) != _stable_fields(after_descriptor)
        or _stable_fields(before) != _stable_fields(after_path)
    ):
        raise ZigToolchainReceiptError("Zig receipt changed while it was read")
    if len(payload) != before.st_size or len(payload) > 4096:
        raise ZigToolchainReceiptError("Zig receipt changed while it was read")
    return payload


def verify_receipt(
    root: Path,
    receipt_path: Path,
    expected_version: str,
    expected_archive_sha256: str,
    expected_tree_sha256: str,
) -> str:
    payload = _read_receipt(receipt_path)
    try:
        decoded = json.loads(payload)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ZigToolchainReceiptError(f"Zig receipt is not canonical JSON: {error}") from error
    if not isinstance(decoded, dict) or set(decoded) != RECEIPT_FIELDS:
        raise ZigToolchainReceiptError("Zig receipt has an unexpected schema")
    if _canonical_receipt_bytes(decoded) != payload:
        raise ZigToolchainReceiptError("Zig receipt is not canonical JSON")
    expected = _receipt_for(
        root, expected_version, expected_archive_sha256, expected_tree_sha256
    )
    if decoded != expected:
        raise ZigToolchainReceiptError(
            "Zig receipt does not match the verified toolchain identity"
        )
    return hashlib.sha256(payload).hexdigest()


def main(arguments: Optional[Sequence[str]] = None) -> int:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)

    identity_parser = subparsers.add_parser("identity")
    identity_parser.add_argument("--root", required=True, type=Path)

    package_parser = subparsers.add_parser("package-store")
    package_parser.add_argument("--root", required=True, type=Path)
    package_parser.add_argument("--expected-sha256", required=True)

    source_parser = subparsers.add_parser("ghostty-source")
    source_parser.add_argument("--root", required=True, type=Path)
    source_parser.add_argument("--expected-sha256", required=True)

    snapshot_parser = subparsers.add_parser("snapshot")
    snapshot_parser.add_argument(
        "--kind", required=True, choices=("toolchain", "package-store", "ghostty-source")
    )
    snapshot_parser.add_argument("--source", required=True, type=Path)
    snapshot_parser.add_argument("--destination", required=True, type=Path)
    snapshot_parser.add_argument("--expected-sha256", required=True)

    for command in ("create", "verify"):
        command_parser = subparsers.add_parser(command)
        command_parser.add_argument("--root", required=True, type=Path)
        command_parser.add_argument("--receipt", required=True, type=Path)
        command_parser.add_argument("--expected-version", required=True)
        command_parser.add_argument("--expected-archive-sha256", required=True)
        command_parser.add_argument("--expected-tree-sha256", required=True)

    parsed = parser.parse_args(arguments)
    try:
        if parsed.command == "identity":
            identity = closed_tree_identity(parsed.root)
            identity["canonical_root"] = str(identity["canonical_root"])
            print(json.dumps(identity, sort_keys=True, separators=(",", ":")))
            return 0
        if parsed.command == "package-store":
            print(verify_package_store(parsed.root, parsed.expected_sha256))
            return 0
        if parsed.command == "ghostty-source":
            print(verify_ghostty_source(parsed.root, parsed.expected_sha256))
            return 0
        if parsed.command == "snapshot":
            print(
                json.dumps(
                    create_private_snapshot(
                        parsed.kind,
                        parsed.source,
                        parsed.destination,
                        parsed.expected_sha256,
                    ),
                    sort_keys=True,
                    separators=(",", ":"),
                )
            )
            return 0
        if parsed.command == "create":
            receipt_sha256 = write_receipt(
                parsed.root,
                parsed.receipt,
                parsed.expected_version,
                parsed.expected_archive_sha256,
                parsed.expected_tree_sha256,
            )
        else:
            receipt_sha256 = verify_receipt(
                parsed.root,
                parsed.receipt,
                parsed.expected_version,
                parsed.expected_archive_sha256,
                parsed.expected_tree_sha256,
            )
        print(receipt_sha256)
        return 0
    except (
        OSError,
        UnicodeError,
        ValueError,
        ZigPackageStoreError,
        ZigToolchainReceiptError,
    ) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
