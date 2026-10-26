#!/usr/bin/env python3
"""Descriptor-anchored publication and residue preservation for the bridge golden gate."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import secrets
import shutil
import stat
import sys
from typing import Optional, Tuple


DirectoryIdentity = Tuple[int, int]
RegularIdentity = Tuple[int, int, int, int, int, int]
DIRECTORY_FLAGS = (
    os.O_RDONLY
    | getattr(os, "O_DIRECTORY", 0)
    | getattr(os, "O_NOFOLLOW", 0)
    | getattr(os, "O_CLOEXEC", 0)
)
FILE_FLAGS = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_CLOEXEC", 0)
class GoldenFilesystemError(RuntimeError):
    """A filesystem identity or ownership boundary was violated."""


def _directory_identity(metadata: os.stat_result) -> DirectoryIdentity:
    return metadata.st_dev, metadata.st_ino


def _regular_identity(metadata: os.stat_result) -> RegularIdentity:
    return (
        metadata.st_dev,
        metadata.st_ino,
        metadata.st_mode,
        metadata.st_nlink,
        metadata.st_size,
        metadata.st_mtime_ns,
    )


def _entry_name(name: str) -> str:
    if not name or os.path.basename(name) != name or name in (".", ".."):
        raise GoldenFilesystemError("unsafe filesystem entry name")
    return name


def _open_directory(path: Path, expected: Optional[DirectoryIdentity] = None) -> int:
    try:
        descriptor = os.open(path, DIRECTORY_FLAGS)
        opened = os.fstat(descriptor)
        observed = _directory_identity(opened)
        if not stat.S_ISDIR(opened.st_mode):
            raise GoldenFilesystemError("path is not an ordinary directory")
        if expected is not None and observed != expected:
            raise GoldenFilesystemError("directory was substituted")
        if _directory_identity(path.lstat()) != observed:
            raise GoldenFilesystemError("directory identity changed while it was opened")
        return descriptor
    except Exception:
        if "descriptor" in locals():
            os.close(descriptor)
        raise


def snapshot_directory(path: Path) -> DirectoryIdentity:
    descriptor = _open_directory(Path(path))
    try:
        return _directory_identity(os.fstat(descriptor))
    finally:
        os.close(descriptor)


def _open_regular(
    parent_fd: int,
    name: str,
    expected: Optional[RegularIdentity] = None,
) -> Tuple[int, RegularIdentity]:
    name = _entry_name(name)
    metadata = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
    observed = _regular_identity(metadata)
    if not stat.S_ISREG(metadata.st_mode) or metadata.st_nlink != 1:
        raise GoldenFilesystemError("file must be an ordinary singly linked file")
    if expected is not None and observed != expected:
        raise GoldenFilesystemError("regular-file identity changed after preflight")
    descriptor = os.open(name, FILE_FLAGS, dir_fd=parent_fd)
    if _regular_identity(os.fstat(descriptor)) != observed:
        os.close(descriptor)
        raise GoldenFilesystemError("regular-file identity changed while it was opened")
    return descriptor, observed


def snapshot_regular(
    parent: Path,
    parent_identity: DirectoryIdentity,
    name: str,
    *,
    allow_absent: bool = False,
) -> Optional[RegularIdentity]:
    parent_fd = _open_directory(Path(parent), parent_identity)
    try:
        try:
            descriptor, observed = _open_regular(parent_fd, name)
        except FileNotFoundError:
            if allow_absent:
                return None
            raise GoldenFilesystemError("required regular file is missing")
        try:
            if _regular_identity(os.stat(name, dir_fd=parent_fd, follow_symlinks=False)) != observed:
                raise GoldenFilesystemError("regular-file identity changed during snapshot")
            return observed
        finally:
            os.close(descriptor)
    finally:
        os.close(parent_fd)


def cleanup_owned_directory(path: Path, expected: DirectoryIdentity) -> None:
    path = Path(path).absolute()
    if (
        not path.name
        or path.name in (".", "..")
        or not path.name.startswith("native-bridge-golden.")
    ):
        raise GoldenFilesystemError("refusing unsafe owned-directory path")
    parent_fd = _open_directory(path.parent)
    root_fd = -1
    try:
        before = os.stat(path.name, dir_fd=parent_fd, follow_symlinks=False)
        if not stat.S_ISDIR(before.st_mode) or _directory_identity(before) != expected:
            raise GoldenFilesystemError("owned run directory was substituted")
        root_fd = os.open(path.name, DIRECTORY_FLAGS, dir_fd=parent_fd)
        if _directory_identity(os.fstat(root_fd)) != expected:
            raise GoldenFilesystemError("owned run directory changed before cleanup")
        after = os.stat(path.name, dir_fd=parent_fd, follow_symlinks=False)
        if not stat.S_ISDIR(after.st_mode) or _directory_identity(after) != expected:
            raise GoldenFilesystemError("owned run directory changed during cleanup")
        tombstone = _entry_name(f".{path.name}.cleanup.{secrets.token_hex(16)}")
        os.rename(
            path.name,
            tombstone,
            src_dir_fd=parent_fd,
            dst_dir_fd=parent_fd,
        )
        moved = os.stat(tombstone, dir_fd=parent_fd, follow_symlinks=False)
        if not stat.S_ISDIR(moved.st_mode) or _directory_identity(moved) != expected:
            raise GoldenFilesystemError(
                "owned run directory was substituted during cleanup; residue preserved"
            )
        parent_identity = _directory_identity(os.fstat(parent_fd))
        if _directory_identity(path.parent.lstat()) != parent_identity:
            raise GoldenFilesystemError(
                "owned run parent changed during cleanup; residue preserved"
            )
        shutil.rmtree(path.parent / tombstone)
    finally:
        if root_fd >= 0:
            os.close(root_fd)
        os.close(parent_fd)


def cleanup_owned_regular(
    parent: Path,
    parent_identity: DirectoryIdentity,
    name: str,
    expected: RegularIdentity,
) -> None:
    parent_fd = _open_directory(Path(parent), parent_identity)
    descriptor = -1
    try:
        descriptor, observed = _open_regular(parent_fd, name)
        if observed[:2] != expected[:2]:
            raise GoldenFilesystemError("owned temporary result was substituted")
        if _regular_identity(os.stat(name, dir_fd=parent_fd, follow_symlinks=False)) != observed:
            raise GoldenFilesystemError("owned temporary result was substituted")
        tombstone = _entry_name(f".{name}.cleanup.{secrets.token_hex(16)}")
        os.rename(name, tombstone, src_dir_fd=parent_fd, dst_dir_fd=parent_fd)
        moved = os.stat(tombstone, dir_fd=parent_fd, follow_symlinks=False)
        if _regular_identity(moved)[:2] != expected[:2]:
            raise GoldenFilesystemError(
                "owned temporary result was substituted during cleanup; residue preserved"
            )
        os.unlink(tombstone, dir_fd=parent_fd)
    finally:
        if descriptor >= 0:
            os.close(descriptor)
        os.close(parent_fd)


def _same_bytes(left_fd: int, right_fd: int) -> bool:
    os.lseek(left_fd, 0, os.SEEK_SET)
    os.lseek(right_fd, 0, os.SEEK_SET)
    while True:
        left = os.read(left_fd, 1024 * 1024)
        right = os.read(right_fd, 1024 * 1024)
        if left != right:
            return False
        if not left:
            return True


def _copy_to_exclusive_destination(
    destination_parent_fd: int,
    source_fd: int,
    source_identity: RegularIdentity,
    destination: str,
) -> tuple[int, os.stat_result]:
    destination = _entry_name(destination)
    flags = (
        os.O_RDWR
        | os.O_CREAT
        | os.O_EXCL
        | getattr(os, "O_NOFOLLOW", 0)
        | getattr(os, "O_CLOEXEC", 0)
    )
    destination_fd = -1
    try:
        try:
            destination_fd = os.open(
                destination,
                flags,
                0o600,
                dir_fd=destination_parent_fd,
            )
        except FileExistsError as error:
            raise GoldenFilesystemError(
                "result destination appeared during exclusive publication"
            ) from error
        if _regular_identity(os.fstat(source_fd)) != source_identity:
            raise GoldenFilesystemError("verified temporary result changed before publication")
        os.lseek(source_fd, 0, os.SEEK_SET)
        while block := os.read(source_fd, 1024 * 1024):
            offset = 0
            while offset < len(block):
                written = os.write(destination_fd, block[offset:])
                if written <= 0:
                    raise GoldenFilesystemError("exclusive result publication made no progress")
                offset += written
        os.fsync(destination_fd)
        os.fchmod(destination_fd, 0o644)
        os.fsync(destination_fd)
        if _regular_identity(os.fstat(source_fd)) != source_identity:
            raise GoldenFilesystemError("verified temporary result changed during publication")
        published = os.fstat(destination_fd)
        observed = os.stat(
            destination,
            dir_fd=destination_parent_fd,
            follow_symlinks=False,
        )
        if (
            not stat.S_ISREG(published.st_mode)
            or published.st_nlink != 1
            or _regular_identity(observed) != _regular_identity(published)
            or not _same_bytes(source_fd, destination_fd)
        ):
            raise GoldenFilesystemError(
                "exclusive result destination differs from the verified temporary descriptor"
            )
        return destination_fd, published
    except Exception:
        if destination_fd >= 0:
            os.close(destination_fd)
        raise


def _replace_verified_destination(
    destination_parent_fd: int,
    source_fd: int,
    source_identity: RegularIdentity,
    destination: str,
    destination_identity: RegularIdentity,
) -> tuple[int, os.stat_result]:
    """Atomically refresh a verified regular result inside its anchored parent."""
    replacement = f".{_entry_name(destination)}.replacement.{secrets.token_hex(16)}"
    replacement_fd = -1
    try:
        replacement_fd, replacement_metadata = _copy_to_exclusive_destination(
            destination_parent_fd,
            source_fd,
            source_identity,
            replacement,
        )
        live_destination = os.stat(
            destination,
            dir_fd=destination_parent_fd,
            follow_symlinks=False,
        )
        if _regular_identity(live_destination) != destination_identity:
            raise GoldenFilesystemError("result destination changed before atomic refresh")
        os.replace(
            replacement,
            destination,
            src_dir_fd=destination_parent_fd,
            dst_dir_fd=destination_parent_fd,
        )
        os.fsync(destination_parent_fd)
        published = os.stat(
            destination,
            dir_fd=destination_parent_fd,
            follow_symlinks=False,
        )
        if _regular_identity(published) != _regular_identity(replacement_metadata):
            raise GoldenFilesystemError("atomically refreshed result has unexpected identity")
        if not _same_bytes(source_fd, replacement_fd):
            raise GoldenFilesystemError("atomically refreshed result differs from verified bytes")
        return replacement_fd, published
    except Exception:
        try:
            os.unlink(replacement, dir_fd=destination_parent_fd)
        except FileNotFoundError:
            pass
        if replacement_fd >= 0:
            os.close(replacement_fd)
        raise


def publish_result(
    source_parent: Path,
    source_parent_identity: DirectoryIdentity,
    temporary_name: str,
    temporary_identity: RegularIdentity,
    destination_parent: Path,
    destination_parent_identity: DirectoryIdentity,
    result_name: str,
    result_initial_identity: Optional[RegularIdentity],
) -> None:
    temporary_name = _entry_name(temporary_name)
    result_name = _entry_name(result_name)
    source_parent_fd = -1
    destination_parent_fd = -1
    try:
        source_parent_fd = _open_directory(
            Path(source_parent),
            source_parent_identity,
        )
    except (GoldenFilesystemError, OSError) as error:
        raise GoldenFilesystemError("temporary source parent was substituted") from error
    try:
        destination_parent_fd = _open_directory(
            Path(destination_parent),
            destination_parent_identity,
        )
    except (GoldenFilesystemError, OSError) as error:
        os.close(source_parent_fd)
        raise GoldenFilesystemError("result parent was substituted") from error
    temporary_fd = -1
    result_fd = -1
    published_fd = -1
    try:
        temporary_fd, _ = _open_regular(
            source_parent_fd,
            temporary_name,
            temporary_identity,
        )
        if stat.S_IMODE(os.fstat(temporary_fd).st_mode) != 0o644:
            raise GoldenFilesystemError("temporary result mode is not 0644")
        if result_initial_identity is None:
            published_fd, published = _copy_to_exclusive_destination(
                destination_parent_fd,
                temporary_fd,
                temporary_identity,
                result_name,
            )
        else:
            result_fd, observed = _open_regular(
                destination_parent_fd,
                result_name,
                result_initial_identity,
            )
            if _same_bytes(temporary_fd, result_fd):
                if _regular_identity(
                    os.stat(
                        result_name,
                        dir_fd=destination_parent_fd,
                        follow_symlinks=False,
                    )
                ) != observed:
                    raise GoldenFilesystemError("result destination changed during exact reuse")
                published = os.stat(
                    result_name,
                    dir_fd=destination_parent_fd,
                    follow_symlinks=False,
                )
                if _regular_identity(published) != observed:
                    raise GoldenFilesystemError(
                        "reused result changed before publication completed"
                    )
            else:
                published_fd, published = _replace_verified_destination(
                    destination_parent_fd,
                    temporary_fd,
                    temporary_identity,
                    result_name,
                    observed,
                )
        if not stat.S_ISREG(published.st_mode) or published.st_nlink != 1:
            raise GoldenFilesystemError("published result must be an ordinary singly linked file")
        if stat.S_IMODE(published.st_mode) != 0o644:
            raise GoldenFilesystemError("published result mode is not 0644")
        if snapshot_directory(Path(source_parent)) != source_parent_identity:
            raise GoldenFilesystemError(
                "temporary source parent changed before publication completed"
            )
        if snapshot_directory(Path(destination_parent)) != destination_parent_identity:
            raise GoldenFilesystemError("result parent changed before publication completed")
    finally:
        if published_fd >= 0:
            os.close(published_fd)
        if result_fd >= 0:
            os.close(result_fd)
        if temporary_fd >= 0:
            os.close(temporary_fd)
        os.close(destination_parent_fd)
        os.close(source_parent_fd)


def _identity(value: str, length: int):
    decoded = json.loads(value)
    if not isinstance(decoded, list) or len(decoded) != length or not all(
        isinstance(item, int) for item in decoded
    ):
        raise GoldenFilesystemError("malformed filesystem identity")
    return tuple(decoded)


def main() -> int:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="operation", required=True)
    directory = subparsers.add_parser("snapshot-directory")
    directory.add_argument("path", type=Path)
    regular = subparsers.add_parser("snapshot-regular")
    regular.add_argument("parent", type=Path)
    regular.add_argument("parent_identity")
    regular.add_argument("name")
    regular.add_argument("--allow-absent", action="store_true")
    cleanup_directory = subparsers.add_parser("cleanup-directory")
    cleanup_directory.add_argument("path", type=Path)
    cleanup_directory.add_argument("identity")
    cleanup_regular = subparsers.add_parser("cleanup-regular")
    cleanup_regular.add_argument("parent", type=Path)
    cleanup_regular.add_argument("parent_identity")
    cleanup_regular.add_argument("name")
    cleanup_regular.add_argument("identity")
    publish = subparsers.add_parser("publish")
    publish.add_argument("source_parent", type=Path)
    publish.add_argument("source_parent_identity")
    publish.add_argument("temporary_name")
    publish.add_argument("temporary_identity")
    publish.add_argument("destination_parent", type=Path)
    publish.add_argument("destination_parent_identity")
    publish.add_argument("result_name")
    publish.add_argument("result_initial_identity")
    arguments = parser.parse_args()
    try:
        if arguments.operation == "snapshot-directory":
            print(json.dumps(snapshot_directory(arguments.path), separators=(",", ":")))
        elif arguments.operation == "snapshot-regular":
            observed = snapshot_regular(
                arguments.parent,
                _identity(arguments.parent_identity, 2),
                arguments.name,
                allow_absent=arguments.allow_absent,
            )
            print("absent" if observed is None else json.dumps(observed, separators=(",", ":")))
        elif arguments.operation == "cleanup-directory":
            cleanup_owned_directory(arguments.path, _identity(arguments.identity, 2))
        elif arguments.operation == "cleanup-regular":
            cleanup_owned_regular(
                arguments.parent,
                _identity(arguments.parent_identity, 2),
                arguments.name,
                _identity(arguments.identity, 6),
            )
        else:
            publish_result(
                arguments.source_parent,
                _identity(arguments.source_parent_identity, 2),
                arguments.temporary_name,
                _identity(arguments.temporary_identity, 6),
                arguments.destination_parent,
                _identity(arguments.destination_parent_identity, 2),
                arguments.result_name,
                None
                if arguments.result_initial_identity == "absent"
                else _identity(arguments.result_initial_identity, 6),
            )
    except (GoldenFilesystemError, OSError, ValueError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
