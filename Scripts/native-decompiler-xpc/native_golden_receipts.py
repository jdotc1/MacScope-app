#!/usr/bin/env python3
"""Digest and staged-package receipt reuse for developer native goldens only.

Shared-view mode requires metadata-bound receipts. Normal standalone/Release
execution keeps stable full hashing and the existing strict package verifier.
"""
from __future__ import annotations
import argparse
import hashlib
import json
import os
from pathlib import Path
import stat
import sys

sys.dont_write_bytecode = True
FIELDS = ("st_dev", "st_ino", "st_mode", "st_nlink", "st_size", "st_mtime_ns", "st_ctime_ns")


def fields(metadata):
    return [getattr(metadata, name) for name in FIELDS]


def ordinary(path):
    metadata = path.lstat()
    if not stat.S_ISREG(metadata.st_mode) or metadata.st_nlink != 1:
        raise ValueError("golden digest requires an ordinary singly linked file")
    return metadata


def receipt_root():
    root = Path(os.environ["MACSCOPE_NATIVE_SOURCE_IDENTITY_RECEIPT_ROOT"])
    metadata = root.lstat()
    if (not root.is_absolute() or root.resolve(strict=True) != root
            or not stat.S_ISDIR(metadata.st_mode) or metadata.st_uid != os.getuid()
            or stat.S_IMODE(metadata.st_mode) & 0o077):
        raise ValueError("golden digest receipts require a private canonical directory")
    return root


def package_snapshot(root):
    # This reader anchors an existing staged receipt or the shared source view,
    # validates its closed metadata snapshot, and never rehashes admitted files.
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    import stage_verified_package as stage
    canonical, descriptor, root_fields, snapshot, identity = stage._open_verified_materialization(root, "native golden package")
    try:
        stage._revalidate_anchored_materialization(canonical, descriptor, root_fields, snapshot, "native golden package")
        return canonical, snapshot, identity
    finally:
        os.close(descriptor)


def stable_hash(path):
    before = ordinary(path)
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
    try:
        if fields(os.fstat(descriptor)) != fields(before):
            raise ValueError("golden file moved before hashing")
        digest = hashlib.sha256()
        while block := os.read(descriptor, 1024 * 1024):
            digest.update(block)
        if fields(os.fstat(descriptor)) != fields(before) or fields(ordinary(path)) != fields(before):
            raise ValueError("golden file moved while hashing")
        return digest.hexdigest(), fields(before)
    finally:
        os.close(descriptor)


def digest(path, materialization=None):
    mode = os.environ.get("MACSCOPE_NATIVE_VERIFICATION_RECEIPT_MODE", "")
    if not mode:
        return stable_hash(path)[0]
    if mode != "shared-view":
        raise ValueError("unsupported native golden verification receipt mode")
    if path.resolve(strict=True) != path:
        raise ValueError("golden digest path must be canonical")
    observed = fields(ordinary(path))
    if materialization is not None and path.is_relative_to(materialization):
        canonical, snapshot, _ = package_snapshot(materialization)
        relative = path.relative_to(canonical).as_posix()
        row = next((item for item in snapshot if item[0] == relative), None)
        if row is None or row[1] != "file" or list(row[2]) != observed or row[3] is None:
            raise ValueError("golden package leaf differs from staged receipt")
        return row[3]
    root = receipt_root()
    key = hashlib.sha256(str(path).encode()).hexdigest()
    receipt = root / ("golden-digest-" + key + ".json")
    if receipt.exists() or receipt.is_symlink():
        before = ordinary(receipt)
        if before.st_uid != os.getuid() or before.st_mode & 0o222:
            raise ValueError("golden digest receipt must be immutable and owner controlled")
        value = json.loads(receipt.read_bytes())
        if (set(value) != {"version", "path", "metadata", "sha256"} or value["version"] != 1
                or value["path"] != str(path) or value["metadata"] != observed
                or not isinstance(value["sha256"], str) or len(value["sha256"]) != 64
                or any(character not in "0123456789abcdef" for character in value["sha256"])
                or fields(ordinary(receipt)) != fields(before) or fields(ordinary(path)) != observed):
            raise ValueError("golden digest receipt is stale or malformed; refusing repeat hashing")
        return value["sha256"]
    value, metadata = stable_hash(path)
    document = {"version": 1, "path": str(path), "metadata": metadata, "sha256": value}
    descriptor = os.open(receipt, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o400)
    with os.fdopen(descriptor, "w") as handle:
        json.dump(document, handle, sort_keys=True, separators=(",", ":"))
        handle.write("\n")
    return value


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("digest", "verify-package"))
    parser.add_argument("--path", type=Path)
    parser.add_argument("--materialization-root", type=Path, required=True)
    arguments = parser.parse_args()
    try:
        if arguments.command == "verify-package":
            if os.environ.get("MACSCOPE_NATIVE_VERIFICATION_RECEIPT_MODE") != "shared-view":
                raise ValueError("receipt package admission requires shared-view mode")
            package_snapshot(arguments.materialization_root)
        else:
            if arguments.path is None:
                raise ValueError("digest requires --path")
            print(digest(arguments.path, arguments.materialization_root))
        return 0
    except (OSError, ValueError, KeyError) as error:
        print(f"native golden receipt error: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
