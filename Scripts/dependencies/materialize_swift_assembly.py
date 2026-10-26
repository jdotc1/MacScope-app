#!/usr/bin/env python3
"""Materialize the reviewed swiftbin/swift-assembly direct-source closure.

This explicit operator tool accepts only the frozen clean local Git checkout. It
does not acquire source or use a package manager. Normal MacScope builds consume
only the checked-in, independently verifiable materialization.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import stat
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable


SCHEMA_VERSION = 1
PROVIDER = "swiftbin/swift-assembly"
REPOSITORY = "https://github.com/swiftbin/swift-assembly.git"
REVISION = "b6798dbd0081ec989d25b5a0676ab8cbd36bd9b1"
GIT_TREE = "69fde307d20e1e8c73261cffffbf5a11f526a94c"
LICENSE_SHA256 = "00511a028804276eb97fcc0cdba28ce973bcaf37cfa555d3cf934d9cec08f7cb"
MAX_FILES = 32
MAX_FILE_BYTES = 2 * 1024 * 1024
MAX_TOTAL_BYTES = 4 * 1024 * 1024
EXPECTED_ROOT_ENTRIES = frozenset(
    {
        "Sources", "LICENSE", "NOTICE.md", "PATCHES.md",
        "SOURCE_IDENTITY.json", "MATERIALIZATION.json",
    }
)


@dataclass(frozen=True)
class SourceFile:
    upstream_path: str
    vendor_path: str
    size: int
    git_blob_sha1: str
    sha256: str


SOURCE_FILES = (
    SourceFile("Sources/Assembly/ARM64/A64BitmaskImmediate.swift", "Sources/ARM64/A64BitmaskImmediate.swift", 2882, "22dda6b16d7707f901d1825e2bca385a51085560", "135d73a6ff8d5873878e2678822c14941212218c835591187c15a481ff820f2d"),
    SourceFile("Sources/Assembly/ARM64/A64Decoder.swift", "Sources/ARM64/A64Decoder.swift", 162630, "b419ba54b77ca6c47bbcffe0fab44b88855658ec", "e06dd55c3a11db9e3b6af175b06dcac0f0e61f62f444ead21cbf565ba44bcc97"),
    SourceFile("Sources/Assembly/ARM64/A64Encoder.swift", "Sources/ARM64/A64Encoder.swift", 95333, "36a09ba7d6cd7f84852a9ff325255d139e6a0bed", "246c2bb18be5d29eeef831f2a7d275ff8f1645128a105ebceca85c8fa9983298"),
    SourceFile("Sources/Assembly/ARM64/A64FloatingPointEncoder.swift", "Sources/ARM64/A64FloatingPointEncoder.swift", 13024, "1900b06c010c7ef8c0be99d022e0d85cc311661d", "548f0de4f351defc8e1145554fa021abdfca094cf5342720f939a54a310b79f6"),
    SourceFile("Sources/Assembly/ARM64/A64Formatter.swift", "Sources/ARM64/A64Formatter.swift", 48794, "dd1fcf133094147b4b35b430b070434cda553f2c", "2afc01f7f2b720a1ffec8294277e708d99af708ae334777c8313d7820498181f"),
    SourceFile("Sources/Assembly/ARM64/A64InstructionFormats.swift", "Sources/ARM64/A64InstructionFormats.swift", 43291, "4ff5f36b2eac86170bc9bae10f32ab1f249ccfff", "3defbf7a11e3ca577cfcac3d244c77048320f05aaf7e6e78b5f73a2a5bfbb826"),
    SourceFile("Sources/Assembly/ARM64/A64InstructionParser.swift", "Sources/ARM64/A64InstructionParser.swift", 151513, "45516061207153dd2e514c2c3fe00f82ae4269ec", "b30103cc17cf9591889744be61b40618e76d789a3298c89ff34e94d4655afd97"),
    SourceFile("Sources/Assembly/ARM64/A64Model.swift", "Sources/ARM64/A64Model.swift", 141736, "c3b5670bc00421de8e995e6aff69e00b23adc591", "13164db2e7f8f46c4e9b72c33c7128b6a8b99f9f82e1939637cf018317c3d49e"),
    SourceFile("Sources/Assembly/ARM64/A64Support.swift", "Sources/ARM64/A64Support.swift", 2245, "a229135af464f2b26b267bc0cd05b5adcfc582ba", "979b3e71bad039929e54685a9ec12aff416bbf1e748da55e58b224f4e6192f3f"),
    SourceFile("Sources/Assembly/ARM64/A64VectorEncoder.swift", "Sources/ARM64/A64VectorEncoder.swift", 69022, "48a7363d97d2f66a8e7a8d1db63b6fe268117f98", "e9cd4aeab65be63bbcd60b8238e627fbf284bcb68214ced32c9d4ed9b5b549b5"),
    SourceFile("Sources/Assembly/ARM64/ARM64Assembler.swift", "Sources/ARM64/ARM64Assembler.swift", 3116, "027a04ccabac51ff98fcaa12ef7df90211d8437a", "4e584fb8c345e44cc8ab133909d4cdd4294682ee20d389df21828413d0872d65"),
    SourceFile("Sources/Assembly/Core/AssemblerError.swift", "Sources/Core/AssemblerError.swift", 2654, "111534dc98f6704c527df1786ab46b89539b1d26", "16b4df3cb0d9371330af8201522a97b7167ce00faf4a494595dcd04f5b2721bd"),
    SourceFile("Sources/Assembly/Core/Endianness.swift", "Sources/Core/Endianness.swift", 77, "f835084e917979299d5f6bce9d47165a3e10592f", "1f446c5a03536bdb511e2a098d0fc33c551e2e21ea620e9365f12a552adf2ce5"),
    SourceFile("Sources/Assembly/Core/ParsedInstruction.swift", "Sources/Core/ParsedInstruction.swift", 246, "128de828fa248443c8e66d407094fde6ad1a765d", "9a3e0b97652da7518f1dd4f5bf3e2038240682db9bb929410d9fd4b2d49cbae3"),
    SourceFile("Sources/Assembly/Core/SourceParser.swift", "Sources/Core/SourceParser.swift", 3332, "8011aa90bebd18cd2f3241096fdbe8919ef3a13e", "220145311620adca2f0fc24149976040f254f00fd4c81a25f942abbd9ea1924e"),
)

NOTICE = """# swift-assembly notice

MacScope incorporates selected, unmodified source files from
`swiftbin/swift-assembly` at commit
`b6798dbd0081ec989d25b5a0676ab8cbd36bd9b1` under the MIT License.
The complete upstream license is preserved in `LICENSE`.

Only the 15 files listed in `SOURCE_IDENTITY.json` are compiled. The upstream
package manifest, tests, examples, generated products, and Git metadata are not
included. Normal MacScope builds perform no dependency acquisition.
"""

PATCHES = """# Local patches

MacScope applies no source patches to the reviewed swift-assembly closure.

`Scripts/dependencies/materialize_swift_assembly.py` copies the exact allowlisted upstream files
and verifies every byte against `ThirdParty/SwiftAssemblyVendor/SOURCE_IDENTITY.json`. Any future
source modification requires a separately reviewed patch record, updated checksums and tree
identity, and requalification of the assembler fallback boundary.
"""


class MaterializationError(RuntimeError):
    pass


def _sha256_bytes(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


def _git_blob_sha1(payload: bytes) -> str:
    header = f"blob {len(payload)}\0".encode("ascii")
    return hashlib.sha1(header + payload).hexdigest()


def _canonical_json(payload: dict[str, object]) -> bytes:
    return (json.dumps(payload, indent=2, sort_keys=True) + "\n").encode("utf-8")


def _write_bytes(path: Path, payload: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("xb") as stream:
        stream.write(payload)
    path.chmod(0o644)


def _ordinary_files(root: Path) -> list[Path]:
    files: list[Path] = []
    total_bytes = 0
    for path in root.rglob("*"):
        relative = path.relative_to(root)
        if any(part.lower().endswith(".xcframework") for part in relative.parts):
            raise MaterializationError(
                f"XCFramework content violates the direct-source contract: {relative}"
            )
        metadata = path.lstat()
        if stat.S_ISLNK(metadata.st_mode):
            raise MaterializationError(f"materialized tree contains a symbolic link: {relative}")
        if stat.S_ISDIR(metadata.st_mode):
            continue
        if not stat.S_ISREG(metadata.st_mode):
            raise MaterializationError(f"materialized tree contains a nonordinary file: {relative}")
        if metadata.st_size > MAX_FILE_BYTES:
            raise MaterializationError(f"materialized file exceeds the size bound: {relative}")
        total_bytes += metadata.st_size
        if total_bytes > MAX_TOTAL_BYTES:
            raise MaterializationError("materialized tree exceeds the total-byte bound")
        files.append(path)
        if len(files) > MAX_FILES:
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


def _run_git(source_root: Path, *arguments: str) -> str:
    environment = os.environ.copy()
    environment.update({"GIT_CONFIG_NOSYSTEM": "1", "GIT_TERMINAL_PROMPT": "0"})
    completed = subprocess.run(
        ["git", *arguments],
        cwd=source_root,
        env=environment,
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    if completed.returncode != 0:
        raise MaterializationError(
            f"local Git identity command failed ({completed.returncode}): git {' '.join(arguments)}"
            + (f"\n{completed.stderr.strip()}" if completed.stderr.strip() else "")
        )
    return completed.stdout.strip()


def _verify_source_closure(source_root: Path) -> None:
    source_directory = source_root / "Sources" / "Assembly"
    if source_directory.is_symlink() or not source_directory.is_dir():
        raise MaterializationError("upstream Assembly source directory is missing or unsafe")
    expected_paths = {record.upstream_path for record in SOURCE_FILES}
    observed_paths: set[str] = set()
    for path in source_directory.rglob("*"):
        relative = path.relative_to(source_root).as_posix()
        metadata = path.lstat()
        if stat.S_ISLNK(metadata.st_mode):
            raise MaterializationError(f"upstream source contains a symbolic link: {relative}")
        if stat.S_ISDIR(metadata.st_mode):
            continue
        if not stat.S_ISREG(metadata.st_mode):
            raise MaterializationError(f"upstream source contains a nonordinary file: {relative}")
        observed_paths.add(relative)
    extras = sorted(observed_paths - expected_paths)
    missing = sorted(expected_paths - observed_paths)
    if extras:
        raise MaterializationError(f"unexpected upstream source: {extras[0]}")
    if missing:
        raise MaterializationError(f"missing required upstream source: {missing[0]}")

    for record in SOURCE_FILES:
        path = source_root / record.upstream_path
        payload = path.read_bytes()
        if len(payload) != record.size or _sha256_bytes(payload) != record.sha256:
            raise MaterializationError(f"source checksum mismatch: {record.upstream_path}")
        if _git_blob_sha1(payload) != record.git_blob_sha1:
            raise MaterializationError(f"Git blob identity mismatch: {record.upstream_path}")

    license_path = source_root / "LICENSE"
    if license_path.is_symlink() or not license_path.is_file():
        raise MaterializationError("upstream MIT license is missing or unsafe")
    if _sha256_bytes(license_path.read_bytes()) != LICENSE_SHA256:
        raise MaterializationError("upstream MIT license checksum mismatch")


def verify_source_root(source_root: Path) -> Path:
    source_root = source_root.expanduser()
    if source_root.is_symlink():
        raise MaterializationError("swift-assembly source must not be a symbolic link")
    source_root = source_root.resolve(strict=True)
    if not source_root.is_dir() or not (source_root / ".git").exists():
        raise MaterializationError("swift-assembly source must be a local Git checkout")
    revision = _run_git(source_root, "rev-parse", "HEAD")
    tree = _run_git(source_root, "rev-parse", "HEAD^{tree}")
    if revision != REVISION or tree != GIT_TREE:
        raise MaterializationError(
            f"swift-assembly Git identity mismatch: expected {REVISION}/{GIT_TREE}, found {revision}/{tree}"
        )
    if _run_git(source_root, "status", "--porcelain", "--untracked-files=all"):
        raise MaterializationError("swift-assembly source checkout is dirty")
    _verify_source_closure(source_root)
    return source_root


def _source_identity() -> dict[str, object]:
    return {
        "schemaVersion": SCHEMA_VERSION,
        "provider": PROVIDER,
        "repository": REPOSITORY,
        "revision": REVISION,
        "gitTree": GIT_TREE,
        "integrationMode": "direct-source",
        "license": {"path": "LICENSE", "sha256": LICENSE_SHA256, "spdx": "MIT"},
        "sourceFiles": [
            {
                "upstreamPath": record.upstream_path,
                "vendorPath": record.vendor_path,
                "size": record.size,
                "gitBlobSHA1": record.git_blob_sha1,
                "sha256": record.sha256,
            }
            for record in SOURCE_FILES
        ],
    }


def _read_json(path: Path, label: str) -> dict[str, object]:
    if path.is_symlink() or not path.is_file() or path.stat().st_size > 1024 * 1024:
        raise MaterializationError(f"{label} is missing, unsafe, or oversized")
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise MaterializationError(f"invalid {label}: {error}") from error
    if not isinstance(payload, dict):
        raise MaterializationError(f"{label} must contain an object")
    return payload


def _materialization_manifest(root: Path, source_identity_sha256: str) -> dict[str, object]:
    files = [
        path for path in _ordinary_files(root)
        if path.relative_to(root).as_posix() != "MATERIALIZATION.json"
    ]
    return {
        "schemaVersion": SCHEMA_VERSION,
        "provider": PROVIDER,
        "integrationMode": "direct-source",
        "sourceIdentityFile": "SOURCE_IDENTITY.json",
        "sourceIdentitySHA256": source_identity_sha256,
        "swiftSourceCount": len(SOURCE_FILES),
        "materializedFileCount": len(files),
        "materializedByteCount": sum(path.stat().st_size for path in files),
        "treeSHA256": _tree_digest(root, excluded=frozenset({"MATERIALIZATION.json"})),
    }


def verify_root(root: Path, *, quiet: bool = False) -> Path:
    root = root.expanduser()
    if root.is_symlink():
        raise MaterializationError("swift-assembly materialization root must not be a symbolic link")
    root = root.resolve(strict=True)
    if not root.is_dir():
        raise MaterializationError("swift-assembly materialization root is not a safe directory")
    observed_entries = {item.name for item in root.iterdir()}
    extras = sorted(observed_entries - EXPECTED_ROOT_ENTRIES)
    missing = sorted(EXPECTED_ROOT_ENTRIES - observed_entries)
    if extras:
        raise MaterializationError(f"unexpected root entry: {extras[0]}")
    if missing:
        raise MaterializationError(f"missing root entry: {missing[0]}")
    _ordinary_files(root)

    expected_sources = {record.vendor_path for record in SOURCE_FILES}
    observed_source_entries: set[str] = set()
    for path in (root / "Sources").rglob("*"):
        if path.is_file() or path.is_symlink():
            observed_source_entries.add(path.relative_to(root).as_posix())
    extras = sorted(observed_source_entries - expected_sources)
    missing = sorted(expected_sources - observed_source_entries)
    if extras:
        raise MaterializationError(f"unexpected source-tree entry: {extras[0]}")
    if missing:
        raise MaterializationError(f"missing materialized source: {missing[0]}")
    for record in SOURCE_FILES:
        payload = (root / record.vendor_path).read_bytes()
        if len(payload) != record.size or _sha256_bytes(payload) != record.sha256:
            raise MaterializationError(f"source checksum mismatch: {record.vendor_path}")

    license_payload = (root / "LICENSE").read_bytes()
    if _sha256_bytes(license_payload) != LICENSE_SHA256:
        raise MaterializationError("materialized MIT license checksum mismatch")
    if (root / "NOTICE.md").read_bytes() != NOTICE.encode("utf-8"):
        raise MaterializationError("materialized notice does not match the reviewed contract")
    if (root / "PATCHES.md").read_bytes() != PATCHES.encode("utf-8"):
        raise MaterializationError("patch ledger does not match the reviewed no-patches contract")

    expected_identity = _source_identity()
    identity_path = root / "SOURCE_IDENTITY.json"
    if _read_json(identity_path, "SOURCE_IDENTITY.json") != expected_identity:
        raise MaterializationError("source identity does not match the reviewed contract")
    identity_sha = _sha256_bytes(identity_path.read_bytes())
    manifest = _read_json(root / "MATERIALIZATION.json", "MATERIALIZATION.json")
    expected_manifest = _materialization_manifest(root, identity_sha)
    if manifest != expected_manifest:
        raise MaterializationError("materialization manifest does not match the observed tree")
    if not quiet:
        print(f"verified {PROVIDER} direct-source materialization: {root}")
    return root


def materialize(source_root: Path, destination: Path, *, quiet: bool = False) -> Path:
    destination = destination.expanduser().resolve(strict=False)
    if destination.exists() or destination.is_symlink():
        raise MaterializationError(f"destination already exists: {destination}")
    source_root = verify_source_root(source_root)
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(
        prefix=".swift-assembly-materialization-", dir=destination.parent
    ) as temporary:
        staged = Path(temporary) / "staged"
        staged.mkdir(mode=0o700)
        for record in SOURCE_FILES:
            _write_bytes(staged / record.vendor_path, (source_root / record.upstream_path).read_bytes())
        _write_bytes(staged / "LICENSE", (source_root / "LICENSE").read_bytes())
        _write_bytes(staged / "NOTICE.md", NOTICE.encode("utf-8"))
        _write_bytes(staged / "PATCHES.md", PATCHES.encode("utf-8"))
        identity_bytes = _canonical_json(_source_identity())
        _write_bytes(staged / "SOURCE_IDENTITY.json", identity_bytes)
        manifest = _materialization_manifest(staged, _sha256_bytes(identity_bytes))
        _write_bytes(staged / "MATERIALIZATION.json", _canonical_json(manifest))
        verify_root(staged, quiet=True)
        staged.rename(destination)
    if not quiet:
        print(f"materialized {PROVIDER} direct source: {destination}")
    return destination


def parse_arguments(argv: Iterable[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    materialize_parser = commands.add_parser("materialize")
    materialize_parser.add_argument("--source-root", type=Path, required=True)
    materialize_parser.add_argument("--destination", type=Path, required=True)
    materialize_parser.add_argument("--quiet", action="store_true")
    verify_parser = commands.add_parser("verify")
    verify_parser.add_argument("--materialization-root", type=Path, required=True)
    verify_parser.add_argument("--quiet", action="store_true")
    return parser.parse_args(argv)


def main(argv: Iterable[str] | None = None) -> int:
    arguments = parse_arguments(argv)
    try:
        if arguments.command == "materialize":
            materialize(arguments.source_root, arguments.destination, quiet=arguments.quiet)
        elif arguments.command == "verify":
            verify_root(arguments.materialization_root, quiet=arguments.quiet)
        else:
            raise AssertionError(arguments.command)
    except (MaterializationError, OSError, subprocess.SubprocessError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
