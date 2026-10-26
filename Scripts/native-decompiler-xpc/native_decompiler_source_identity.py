#!/usr/bin/env python3
"""Compute deterministic identities for the native bridge build surfaces.

The historical DTO field is named ``wrapperGitRevision``.  MacScope now stores
the wrapper profile's SHA-256 content identity in that field so unrelated Git
commits cannot invalidate an otherwise identical native artifact.
"""

from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import stat
import sys
from typing import Iterable, Optional, Sequence, Tuple


WRAPPER_FIXED = (
    "Scripts/native-decompiler-xpc/build_native_bridge.sh",
    "Scripts/native-decompiler-xpc/native_decompiler_source_identity.py",
    "Scripts/native-decompiler-xpc/native_bridge_cache_payload.py",
    "Scripts/native-decompiler-direct/verify_sleigh_package.py",
    "Scripts/native-decompiler-direct/sleigh_package.py",
    "Scripts/qualification/dev_dependency_cache.py",
    "Scripts/qualification/dependency_cache.py",
)
WRAPPER_TREES = ("Tools/NativeDecompilerBridge",)
GOLDEN_FIXED = (
    "Scripts/native-decompiler-xpc/native_golden_receipts.py",
    "Scripts/native-decompiler-xpc/run_native_bridge_golden.sh",
    "Scripts/native-decompiler-xpc/golden_filesystem.py",
    "Scripts/native-decompiler-xpc/stage_verified_package.py",
    "MacScope/Models/NativeDecompilerWire/NativeDecompilerWireBinaryPropertyListValidator.swift",
    "MacScope/Models/NativeDecompilerWire/NativeDecompilerWireCodec.swift",
    "MacScope/Models/NativeDecompilerWire/NativeDecompilerWirePrimitives.swift",
    "MacScope/Models/NativeDecompilerWire/NativeDecompilerWireTargetProfile.swift",
    "MacScope/Models/NativeDecompilerWire/NativeDecompilerWireAuthoredModels.swift",
    "MacScope/Models/NativeDecompilerWire/NativeDecompilerWireCanonicalRequest.swift",
    "MacScope/Models/NativeDecompilerWire/NativeDecompilerWireResultModels.swift",
    "MacScope/Models/NativeDecompilerWire/NativeDecompilerWireSemanticValidator.swift",
    "MacScope/NativeDecompilerXPCService/Bridge/NativeDecompilerWireBridge.hpp",
    "MacScope/NativeDecompilerXPCService/Bridge/NativeDecompilerWireCodec.mm",
    "MacScope/NativeDecompilerXPCService/Bridge/NativeDecompilerObjCBridge.h",
    "MacScope/NativeDecompilerXPCService/Bridge/NativeDecompilerObjCBridge.mm",
    "MacScope/Tests/CoreTests/NativeDecompilerObjCBridgeTests.mm",
    "MacScope/Tests/CoreTests/NativeDecompilerObjCBridgeCrossLanguageTests.swift",
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


class SourceIdentityError(RuntimeError):
    """A declared source escaped its profile or changed during hashing."""


def _metadata_equal(left: os.stat_result, right: os.stat_result) -> bool:
    return all(getattr(left, field) == getattr(right, field) for field in STABLE_FIELDS)


def _canonical_git_mode(mode: int) -> int:
    """Return the only regular-file permission distinction Git preserves."""
    return 0o755 if stat.S_IMODE(mode) & 0o111 else 0o644


def _relative_path(value: str) -> str:
    path = Path(value)
    if path.is_absolute() or not value or any(part in ("", ".", "..") for part in path.parts):
        raise SourceIdentityError("source identity path must be canonical and repository-relative")
    return path.as_posix()


def _tree_files(repository_root: Path, relative_root: str) -> Tuple[str, ...]:
    root = repository_root / _relative_path(relative_root)
    metadata = root.lstat()
    if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISDIR(metadata.st_mode):
        raise SourceIdentityError("source identity tree must be an ordinary directory")
    files = []
    for candidate in root.rglob("*"):
        observed = candidate.lstat()
        if stat.S_ISLNK(observed.st_mode):
            raise SourceIdentityError("source identity profile contains a symlink")
        if stat.S_ISDIR(observed.st_mode):
            continue
        if not stat.S_ISREG(observed.st_mode):
            raise SourceIdentityError("source identity profile contains a non-regular file")
        files.append(candidate.relative_to(repository_root).as_posix())
    return tuple(sorted(files, key=os.fsencode))


def profile_paths(repository_root: Path, profile: str) -> Tuple[str, ...]:
    repository_root = Path(repository_root).resolve(strict=True)
    if profile not in ("wrapper", "golden"):
        raise SourceIdentityError("unknown source identity profile")
    paths = list(WRAPPER_FIXED)
    for tree in WRAPPER_TREES:
        paths.extend(_tree_files(repository_root, tree))
    if profile == "golden":
        paths.extend(GOLDEN_FIXED)
    canonical = tuple(sorted({_relative_path(path) for path in paths}, key=os.fsencode))
    for relative in canonical:
        if not (repository_root / relative).exists():
            raise SourceIdentityError("declared source identity input is missing")
    return canonical


def digest_paths(repository_root: Path, relative_paths: Iterable[str]) -> str:
    repository_root = Path(repository_root).resolve(strict=True)
    root_metadata = repository_root.lstat()
    if stat.S_ISLNK(root_metadata.st_mode) or not stat.S_ISDIR(root_metadata.st_mode):
        raise SourceIdentityError("repository root must be an ordinary directory")
    paths = tuple(sorted({_relative_path(path) for path in relative_paths}, key=os.fsencode))
    if not paths:
        raise SourceIdentityError("source identity profile must not be empty")

    digest = hashlib.sha256(b"MacScope native source identity v1\0")
    for relative in paths:
        candidate = repository_root / relative
        before = candidate.lstat()
        if stat.S_ISLNK(before.st_mode):
            raise SourceIdentityError("source identity input must not be a symlink")
        if not stat.S_ISREG(before.st_mode):
            raise SourceIdentityError("source identity input must be a regular file")
        flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_CLOEXEC", 0)
        descriptor = os.open(candidate, flags)
        try:
            opened = os.fstat(descriptor)
            if not _metadata_equal(before, opened):
                raise SourceIdentityError("source identity input changed before hashing")
            encoded_path = relative.encode("utf-8", errors="strict")
            digest.update(len(encoded_path).to_bytes(8, "big"))
            digest.update(encoded_path)
            # Read/write permission bits vary with checkout umask and do not
            # change a tracked build input's semantics. Git preserves only the
            # executable distinction for regular files, so the sealed identity
            # must use the same canonical mode contract.
            digest.update(_canonical_git_mode(opened.st_mode).to_bytes(4, "big"))
            digest.update(opened.st_size.to_bytes(8, "big"))
            while True:
                block = os.read(descriptor, 1024 * 1024)
                if not block:
                    break
                digest.update(block)
            after_descriptor = os.fstat(descriptor)
        finally:
            os.close(descriptor)
        after_path = candidate.lstat()
        if not _metadata_equal(before, after_descriptor) or not _metadata_equal(before, after_path):
            raise SourceIdentityError("source identity input changed during hashing")
    return digest.hexdigest()


def profile_digest(repository_root: Path, profile: str) -> str:
    repository_root = Path(repository_root).resolve(strict=True)
    paths = profile_paths(repository_root, profile)
    receipt_root = os.environ.get("MACSCOPE_NATIVE_SOURCE_IDENTITY_RECEIPT_ROOT")
    if not receipt_root:
        return digest_paths(repository_root, paths)

    # A caller creates this private directory for one immutable-input build.
    # Only the first call hashes source bytes. Later consumers carry that exact
    # digest while proving the closed file set and every stable identity stayed
    # unchanged; they never create authority from an mtime or cache existence.
    directory = Path(receipt_root)
    metadata = directory.lstat()
    if (not directory.is_absolute() or directory.resolve(strict=True) != directory
            or not stat.S_ISDIR(metadata.st_mode) or metadata.st_uid != os.getuid()
            or stat.S_IMODE(metadata.st_mode) & 0o077):
        raise SourceIdentityError("source identity receipt root must be a private canonical directory")
    if directory == repository_root or repository_root in directory.parents:
        raise SourceIdentityError("source identity receipts must stay outside the source tree")
    key = hashlib.sha256((str(repository_root) + "\0" + profile).encode()).hexdigest()
    receipt = directory / (key + ".json")
    lock = os.open(directory / (key + ".lock"), os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    try:
        fcntl.flock(lock, fcntl.LOCK_EX)
        before = _profile_snapshot(repository_root, paths)
        if receipt.exists() or receipt.is_symlink():
            receipt_metadata = receipt.lstat()
            if (not stat.S_ISREG(receipt_metadata.st_mode) or receipt_metadata.st_nlink != 1
                    or receipt_metadata.st_uid != os.getuid() or receipt_metadata.st_mode & 0o222):
                raise SourceIdentityError("source identity receipt is not immutable and owner-controlled")
            try:
                value = json.loads(receipt.read_text(encoding="utf-8"))
            except (UnicodeError, ValueError) as error:
                raise SourceIdentityError("source identity receipt is malformed") from error
            if (not isinstance(value, dict)
                    or set(value) != {"version", "repository", "profile", "files", "sha256"}
                    or value["version"] != 1 or value["repository"] != str(repository_root)
                    or value["profile"] != profile or value["files"] != before
                    or not isinstance(value["sha256"], str) or len(value["sha256"]) != 64
                    or any(character not in "0123456789abcdef" for character in value["sha256"])):
                raise SourceIdentityError("source inputs changed after their first build identity")
            return value["sha256"]
        digest = digest_paths(repository_root, paths)
        if (profile_paths(repository_root, profile) != paths
                or _profile_snapshot(repository_root, paths) != before):
            raise SourceIdentityError("source inputs changed while recording their build identity")
        value = {"version": 1, "repository": str(repository_root), "profile": profile,
                 "files": before, "sha256": digest}
        descriptor = os.open(receipt, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o400)
        with os.fdopen(descriptor, "w", encoding="utf-8") as output:
            json.dump(value, output, sort_keys=True, separators=(",", ":"))
            output.write("\n")
        return digest
    finally:
        os.close(lock)


def _profile_snapshot(repository_root: Path, paths: Sequence[str]) -> list[list[object]]:
    result = []
    for relative in paths:
        metadata = (repository_root / relative).lstat()
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_nlink != 1:
            raise SourceIdentityError("source identity input must be an ordinary unlinked file")
        result.append([relative, *[getattr(metadata, field) for field in STABLE_FIELDS]])
    return result


def main(arguments: Optional[Sequence[str]] = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repository-root", required=True, type=Path)
    parser.add_argument("--profile", required=True, choices=("wrapper", "golden"))
    parsed = parser.parse_args(arguments)
    try:
        print(profile_digest(parsed.repository_root, parsed.profile))
    except (OSError, SourceIdentityError, UnicodeError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
