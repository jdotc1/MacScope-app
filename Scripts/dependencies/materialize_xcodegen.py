#!/usr/bin/env python3
"""Verify or explicitly materialize the pinned repository-owned XcodeGen tool.

Verification is offline.  Materialization accepts only caller-supplied files;
it never downloads, invokes a package manager, or modifies an existing output.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import stat
import struct
import subprocess
import sys
import tarfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
VENDOR = ROOT / "ThirdParty" / "XcodeGen"
ARCHIVE_NAME = "XcodeGen-2.46.0.tar.gz"
REVISION = "2.46.0"
GIT_REVISION = "8445e778451c7e44237b90281bde622d764b0084"
REPOSITORY = "https://github.com/yonaskolb/XcodeGen"
ARCHIVE_SHA256 = "c83c7bd70255b0ddf4116dadce16bdf0e5939165b43a544e124de294ec84aa27"
BINARY_SHA256 = "5b5d393779d405bbe78a2de8130f0bfaa4f90f7295cd3c8436d620b04aaee49a"
LICENSE_SHA256 = "1e210fcab168d549f41a7495d11a7092836bc38c742baa5e21c0883cd0f1d1a1"
EXPECTED_VERSION = "Version: 2.46.0"
EXPECTED_FILES = frozenset({"LICENSE", "MATERIALIZATION.json", "PATCHES.md", "README.md", "bin/xcodegen", f"source/{ARCHIVE_NAME}"})
EXPECTED_ARCHIVE_LINKS = {"XcodeGen-2.46.0/Sources/XcodeGenKit/SettingPresets": "../../SettingPresets/"}


class VerificationError(RuntimeError):
    pass


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def ordinary_files(root: Path) -> set[str]:
    observed: set[str] = set()
    for path in root.rglob("*"):
        relative = path.relative_to(root).as_posix()
        metadata = path.lstat()
        if stat.S_ISLNK(metadata.st_mode):
            raise VerificationError(f"symbolic link is not permitted: {relative}")
        if stat.S_ISDIR(metadata.st_mode):
            continue
        if not stat.S_ISREG(metadata.st_mode):
            raise VerificationError(f"non-regular file is not permitted: {relative}")
        observed.add(relative)
    return observed


def verify_archive(path: Path) -> None:
    if path.is_symlink() or not path.is_file():
        raise VerificationError("source archive is missing or is not an ordinary file")
    if sha256(path) != ARCHIVE_SHA256:
        raise VerificationError("XcodeGen source archive checksum mismatch")
    try:
        with tarfile.open(path, "r:gz") as archive:
            members = archive.getmembers()
            for member in members:
                name = Path(member.name)
                if name.is_absolute() or ".." in name.parts:
                    raise VerificationError(f"unsafe source archive path: {member.name}")
                if member.issym() or member.islnk():
                    if not member.issym() or EXPECTED_ARCHIVE_LINKS.get(member.name) != member.linkname:
                        raise VerificationError(f"source archive contains an unexpected link: {member.name}")
            roots = {Path(member.name).parts[0] for member in members if member.name}
            if roots != {"XcodeGen-2.46.0"}:
                raise VerificationError("source archive root identity drift")
    except (OSError, tarfile.TarError) as error:
        raise VerificationError(f"source archive is unreadable: {error}") from error


def verify_binary(path: Path) -> None:
    if path.is_symlink() or not path.is_file():
        raise VerificationError("XcodeGen executable is missing or is not an ordinary file")
    if sha256(path) != BINARY_SHA256:
        raise VerificationError("XcodeGen executable checksum mismatch")
    if not path.stat().st_mode & stat.S_IXUSR:
        raise VerificationError("XcodeGen executable is not executable")
    payload = path.read_bytes()[:32]
    if len(payload) < 20:
        raise VerificationError("XcodeGen executable is too small for a Mach-O header")
    magic, cputype = struct.unpack_from("<II", payload)
    if magic != 0xFEEDFACF or cputype != 0x0100000C:
        raise VerificationError("XcodeGen executable is not a thin arm64 Mach-O")
    try:
        result = subprocess.run([str(path), "--version"], check=False, capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.SubprocessError) as error:
        raise VerificationError(f"XcodeGen executable could not be probed: {error}") from error
    if result.returncode != 0 or result.stdout.strip() != EXPECTED_VERSION:
        raise VerificationError("XcodeGen executable version identity drift")


def verify_root(root: Path = VENDOR) -> Path:
    if root.is_symlink() or not root.is_dir():
        raise VerificationError("XcodeGen vendor root is missing or is a symbolic link")
    if ordinary_files(root) != EXPECTED_FILES:
        raise VerificationError("XcodeGen vendor file set drift")
    verify_archive(root / "source" / ARCHIVE_NAME)
    verify_binary(root / "bin" / "xcodegen")
    license_path = root / "LICENSE"
    if sha256(license_path) != LICENSE_SHA256:
        raise VerificationError("XcodeGen license checksum mismatch")
    try:
        metadata = json.loads((root / "MATERIALIZATION.json").read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise VerificationError(f"XcodeGen materialization metadata is invalid: {error}") from error
    if metadata.get("revision") != REVISION or metadata.get("gitRevision") != GIT_REVISION or metadata.get("repository") != REPOSITORY:
        raise VerificationError("XcodeGen metadata identity drift")
    if metadata.get("sourceArchiveSHA256") != ARCHIVE_SHA256 or metadata.get("binarySHA256") != BINARY_SHA256:
        raise VerificationError("XcodeGen metadata checksum drift")
    return root


def verify_tool(binary: Path) -> Path:
    requested = binary.expanduser()
    if not requested.is_absolute():
        raise VerificationError("XcodeGen executable path must be absolute")
    if requested.is_symlink():
        raise VerificationError("XcodeGen executable must not be a symbolic link")
    resolved = requested.resolve(strict=True)
    if resolved != requested:
        raise VerificationError("XcodeGen executable path must be canonical")
    if resolved.name != "xcodegen" or resolved.parent.name != "bin":
        raise VerificationError(
            "XcodeGen executable must be the bin/xcodegen member of a governed root"
        )
    root = verify_root(resolved.parent.parent)
    expected = root / "bin" / "xcodegen"
    if resolved != expected:
        raise VerificationError("XcodeGen executable does not match its governed root")
    return resolved


def materialize(archive: Path, binary: Path, destination: Path) -> Path:
    if destination.exists() or destination.is_symlink():
        raise VerificationError(f"destination already exists; remove it explicitly: {destination}")
    verify_archive(archive)
    verify_binary(binary)
    destination.mkdir(parents=True)
    try:
        (destination / "source").mkdir()
        (destination / "bin").mkdir()
        shutil.copyfile(archive, destination / "source" / ARCHIVE_NAME)
        shutil.copyfile(binary, destination / "bin" / "xcodegen")
        shutil.copymode(binary, destination / "bin" / "xcodegen")
        shutil.copyfile(VENDOR / "LICENSE", destination / "LICENSE")
        shutil.copyfile(VENDOR / "README.md", destination / "README.md")
        shutil.copyfile(VENDOR / "PATCHES.md", destination / "PATCHES.md")
        shutil.copyfile(VENDOR / "MATERIALIZATION.json", destination / "MATERIALIZATION.json")
    except OSError:
        shutil.rmtree(destination)
        raise
    return verify_root(destination)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    verify_parser = subparsers.add_parser("verify")
    verify_parser.add_argument("--root", type=Path, default=VENDOR)
    tool_parser = subparsers.add_parser("verify-tool")
    tool_parser.add_argument("--binary", type=Path, required=True)
    materialize_parser = subparsers.add_parser("materialize")
    materialize_parser.add_argument("--source-archive", type=Path, required=True)
    materialize_parser.add_argument("--binary", type=Path, required=True)
    materialize_parser.add_argument("--destination", type=Path, required=True)
    arguments = parser.parse_args()
    try:
        if arguments.command == "verify":
            verify_root(arguments.root.resolve(strict=True))
        elif arguments.command == "verify-tool":
            verify_tool(arguments.binary)
        else:
            materialize(arguments.source_archive.resolve(strict=True), arguments.binary.resolve(strict=True), arguments.destination)
    except (VerificationError, OSError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    print("XcodeGen verification/materialization passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
