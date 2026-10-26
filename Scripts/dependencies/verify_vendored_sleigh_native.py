#!/usr/bin/env python3
"""Verify the repository-owned native SLEIGH/Ghidra package closure offline."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import stat
import sys


def tree_digest(package: Path) -> tuple[str, int, int, dict[str, str]]:
    files = []
    for candidate in package.rglob("*"):
        mode = candidate.lstat().st_mode
        if stat.S_ISLNK(mode):
            raise ValueError(f"symlink is not permitted: {candidate.relative_to(package)}")
        if stat.S_ISDIR(mode):
            continue
        if not stat.S_ISREG(mode):
            raise ValueError(f"non-regular package member: {candidate.relative_to(package)}")
        files.append(candidate)
    files.sort(key=lambda path: path.relative_to(package).as_posix().encode())
    digest = hashlib.sha256()
    digests = {}
    total = 0
    for candidate in files:
        relative = candidate.relative_to(package).as_posix()
        payload = candidate.read_bytes()
        total += len(payload)
        file_digest = hashlib.sha256(payload).hexdigest()
        digests[relative] = file_digest
        digest.update(relative.encode("utf-8"))
        digest.update(b"\0")
        digest.update(str(len(payload)).encode("ascii"))
        digest.update(b"\0")
        digest.update(file_digest.encode("ascii"))
        digest.update(b"\0")
    return digest.hexdigest(), len(files), total, digests


def verify(root: Path) -> None:
    manifest_path = root / "MATERIALIZATION.json"
    package = root / "package"
    if not manifest_path.is_file() or not package.is_dir():
        raise ValueError("vendored closure requires MATERIALIZATION.json and package/")
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    expected = {
        "schemaVersion": 1,
        "componentId": "sleigh-native-dcp03b4",
        "sleighVersion": "12.1.2",
        "sleighGitRevision": "bfd38a983b4aa53dd386365e1df5ed5499b7e2fb",
        "ghidraVersion": "12.1.2",
        "ghidraGitRevision": "c0f584bf229fffba61b36431f3ce30c0c3e4e682",
    }
    for key, value in expected.items():
        if manifest.get(key) != value:
            raise ValueError(f"unexpected {key}")
    package_record = manifest.get("package", {})
    digest, count, total, digests = tree_digest(package)
    if digest != package_record.get("treeSha256"):
        raise ValueError(f"package tree digest mismatch: {digest}")
    if count != package_record.get("fileCount") or total != package_record.get("totalBytes"):
        raise ValueError("package file count or byte count mismatch")
    for relative, value in package_record.get("criticalFileSha256", {}).items():
        if digests.get(relative) != value:
            raise ValueError(f"critical package member mismatch: {relative}")
    print(json.dumps({"treeSha256": digest, "fileCount": count, "totalBytes": total}, sort_keys=True))


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("root", type=Path)
    arguments = parser.parse_args()
    try:
        verify(arguments.root.resolve(strict=True))
    except (OSError, ValueError, json.JSONDecodeError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
