#!/usr/bin/env python3
"""Offline identity and source-built package checks for native SLEIGH/Ghidra."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import stat
import subprocess
import sys
from typing import Any


SLEIGH_REVISION = "bfd38a983b4aa53dd386365e1df5ed5499b7e2fb"
SLEIGH_GIT_TREE = "20043e94b5933466b0861ad68f07f591f70c0050"
SLEIGH_TREE_SHA256 = "2af879c8587ba6b0913ee53b220f1580c92dd521de7671dc3ece8a750b47e622"
SLEIGH_FILE_COUNT = 41
SLEIGH_TOTAL_BYTES = 131_300

GHIDRA_REVISION = "c0f584bf229fffba61b36431f3ce30c0c3e4e682"
GHIDRA_GIT_TREE = "2dfe30eddeefcd3efc9e49ea58bd725de5bbc4bb"
GHIDRA_TREE_SHA256 = "fdcb64b623e3c881a95f16a29750e83fd124cc08149c347d3e56f58352cbe321"
GHIDRA_FILE_COUNT = 238
GHIDRA_TOTAL_BYTES = 6_942_501

PATCHES = {
    "0001-Fix-UBSAN-errors-in-decompiler.patch": "7f83a4bd158490c5aa58d789b6f655ced6a9b309f4e43a4870cd893b3d36f2e5",
    "0002-Use-stroull-instead-of-stroul-to-parse-address-offse.patch": "8c5ca9c13c87ca4bd456643912205efb26684ccb19055ac60ebe742300a68f39",
    "0003-Ignore-floating-point-test-due-to-compilation-differ.patch": "b4dddb53f41fda93ae9acc633ce1886d2eaa4e8a5328361064633b6733a42a99",
    "0004-Allow-positive-or-negative-NAN-in-decompiler-floatin.patch": "ea78812681b8f1dbede305cc7bde716b7cee16a30005bc90e8304fbfb3df80dd",
    "0005-decompiler-Fix-strict-weak-ordering-TypePartialEnum.patch": "9dbe5ffc7a105e6c199f4027087b553e619691e2402f43a9357ffdec7f55fc11",
    "0006-decompiler-Fix-strict-weak-ordering-PullRecord.patch": "fe52595fc8a2843006f771880e3d49782564770295b4b0a7475ab7d1be435731",
    "0007-decompiler-Fix-strict-weak-ordering-compareFinalOrde.patch": "e4b5581e4513e6a76f1ac07999d5c5e42343e125efdbdc753afbda11d1f13c3f",
    "0008-Fix-UBSAN-signed-left-shift-errors.patch": "2b8a93f1dbf25c9855a85807e0d0c2cd0836789118e3a2a154e24d4a9c20426d",
}

FORBIDDEN_OPTIONAL_GHIDRA_PATHS = (
    "Ghidra/Features/Decompiler/src/decompile/cpp/bfd_arch.cc",
    "Ghidra/Features/Decompiler/src/decompile/cpp/bfd_arch.hh",
    "Ghidra/Features/Decompiler/src/decompile/cpp/codedata.cc",
    "Ghidra/Features/Decompiler/src/decompile/cpp/consolemain.cc",
    "Ghidra/Features/Decompiler/src/decompile/cpp/loadimage_bfd.cc",
    "Ghidra/Features/Decompiler/src/decompile/cpp/loadimage_bfd.hh",
)

REQUIRED_SOURCE_PATHS = (
    "sleigh/CMakeLists.txt",
    "sleigh/LICENSE",
    "sleigh/src/setup-ghidra-source.cmake",
    "ghidra/LICENSE",
    "ghidra/NOTICE",
    "ghidra/DISCLAIMER.md",
    "ghidra/Ghidra/Features/Decompiler/src/decompile/cpp/libdecomp.cc",
    "ghidra/Ghidra/Features/Decompiler/src/decompile/cpp/sleigh.cc",
    "ghidra/Ghidra/Features/Decompiler/src/decompile/cpp/slghparse.cc",
    "ghidra/Ghidra/Features/Decompiler/src/decompile/unittests/testfloatemu.cc",
    "ghidra/Ghidra/Features/Decompiler/src/decompile/datatests/floatprint.xml",
)

CRITICAL_PACKAGE_PATHS = (
    "lib/libdecomp.a",
    "lib/libsla.a",
    "include/sleigh/ghidra/funcdata.hh",
    "include/sleigh/ghidra/heritage.hh",
    "include/sleigh/ghidra/libdecomp.hh",
    "include/sleigh/ghidra/loadimage.hh",
    "include/sleigh/ghidra/prettyprint.hh",
    "include/sleigh/ghidra/printc.hh",
    "include/sleigh/ghidra/sleigh_arch.hh",
    "include/sleigh/ghidra/varnode.hh",
    "lib/cmake/sleigh/sleighConfig.cmake",
    "lib/cmake/sleigh/sleighTargets.cmake",
    "share/sleigh/specfiles/Ghidra/Processors/AARCH64/data/languages/AppleSilicon.ldefs",
    "share/sleigh/specfiles/Ghidra/Processors/AARCH64/data/languages/AARCH64_AppleSilicon.sla",
    "share/sleigh/specfiles/Ghidra/Processors/AARCH64/data/languages/AARCH64.pspec",
    "share/sleigh/specfiles/Ghidra/Processors/AARCH64/data/languages/AARCH64_apple.cspec",
)


class SourceContractError(RuntimeError):
    pass


class DuplicateKey(ValueError):
    pass


def _object_no_duplicates(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise DuplicateKey(key)
        result[key] = value
    return result


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        while chunk := stream.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def analyze_tree(root: Path) -> dict[str, object]:
    if root.is_symlink() or not root.is_dir():
        raise SourceContractError(f"source root must be an ordinary directory: {root}")
    files: list[Path] = []
    for candidate in root.rglob("*"):
        mode = candidate.lstat().st_mode
        if stat.S_ISLNK(mode):
            raise SourceContractError(f"symlink is not permitted: {candidate.relative_to(root)}")
        if stat.S_ISDIR(mode):
            continue
        if not stat.S_ISREG(mode):
            raise SourceContractError(f"non-regular source member: {candidate.relative_to(root)}")
        files.append(candidate)
    files.sort(key=lambda path: path.relative_to(root).as_posix().encode("utf-8"))
    digest = hashlib.sha256()
    total = 0
    for candidate in files:
        relative = candidate.relative_to(root).as_posix()
        size = candidate.stat().st_size
        member_digest = sha256(candidate)
        total += size
        digest.update(relative.encode("utf-8"))
        digest.update(b"\0")
        digest.update(str(size).encode("ascii"))
        digest.update(b"\0")
        digest.update(member_digest.encode("ascii"))
        digest.update(b"\0")
    return {
        "treeSha256": digest.hexdigest(),
        "fileCount": len(files),
        "totalBytes": total,
    }


def load_manifest(path: Path) -> dict[str, Any]:
    if path.is_symlink() or not path.is_file():
        raise SourceContractError("source manifest must be an ordinary file")
    try:
        value = json.loads(path.read_text(encoding="utf-8"), object_pairs_hook=_object_no_duplicates)
    except DuplicateKey as error:
        raise SourceContractError(f"source manifest contains duplicate key: {error.args[0]}") from error
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        raise SourceContractError(f"source manifest is malformed: {error}") from error
    if not isinstance(value, dict):
        raise SourceContractError("source manifest must be an object")
    return value


def verify_source(root: Path) -> dict[str, object]:
    root = root.resolve(strict=True)
    manifest = load_manifest(root / "MATERIALIZATION.json")
    if set(manifest) != {"schemaVersion", "componentId", "sleigh", "ghidra", "patches", "build"}:
        raise SourceContractError("source manifest has an unexpected shape")
    if manifest["schemaVersion"] != 1 or manifest["componentId"] != "sleigh-native-source-dcp03b4":
        raise SourceContractError("source manifest identity is unsupported")

    expected = {
        "sleigh": {
            "repository": "https://github.com/lifting-bits/sleigh",
            "revision": SLEIGH_REVISION,
            "gitTree": SLEIGH_GIT_TREE,
            "relativeRoot": "sleigh",
            "treeSha256": SLEIGH_TREE_SHA256,
            "fileCount": SLEIGH_FILE_COUNT,
            "totalBytes": SLEIGH_TOTAL_BYTES,
            "license": "sleigh/LICENSE",
        },
        "ghidra": {
            "repository": "https://github.com/NationalSecurityAgency/ghidra",
            "revision": GHIDRA_REVISION,
            "gitTree": GHIDRA_GIT_TREE,
            "relativeRoot": "ghidra",
            "treeSha256": GHIDRA_TREE_SHA256,
            "fileCount": GHIDRA_FILE_COUNT,
            "totalBytes": GHIDRA_TOTAL_BYTES,
            "license": "ghidra/LICENSE",
            "notice": "ghidra/NOTICE",
            "disclaimer": "ghidra/DISCLAIMER.md",
            "excludedOptionalPaths": list(FORBIDDEN_OPTIONAL_GHIDRA_PATHS),
        },
    }
    for component, record in expected.items():
        if manifest.get(component) != record:
            raise SourceContractError(f"{component} manifest record does not match the frozen contract")
        analysis = analyze_tree(root / record["relativeRoot"])
        for key in ("treeSha256", "fileCount", "totalBytes"):
            if analysis[key] != record[key]:
                raise SourceContractError(f"{component} source {key} mismatch")

    patch_root = root / "sleigh/src/patches/stable"
    expected_patches = [{"path": name, "sha256": digest} for name, digest in PATCHES.items()]
    if manifest.get("patches") != expected_patches:
        raise SourceContractError("patch manifest does not match the frozen upstream patch series")
    for name, expected_digest in PATCHES.items():
        path = patch_root / name
        if path.is_symlink() or not path.is_file() or sha256(path) != expected_digest:
            raise SourceContractError(f"upstream patch mismatch: {name}")

    for relative in REQUIRED_SOURCE_PATHS:
        candidate = root / relative
        if candidate.is_symlink() or not candidate.is_file():
            raise SourceContractError(f"required source member is missing: {relative}")
    for relative in FORBIDDEN_OPTIONAL_GHIDRA_PATHS:
        if (root / "ghidra" / relative).exists():
            raise SourceContractError(f"optional GPL/BFD source is prohibited: {relative}")

    build = manifest.get("build")
    if build != {
        "system": "CMake and Ninja",
        "network": "disabled",
        "ghidraPatchesAppliedOutsideRepository": True,
        "output": "caller-supplied absolute external work root",
    }:
        raise SourceContractError("source build policy record is unsupported")
    return {"sleigh": analyze_tree(root / "sleigh"), "ghidra": analyze_tree(root / "ghidra")}


def _archive_architectures(path: Path) -> list[str]:
    completed = subprocess.run(
        ["/usr/bin/lipo", "-archs", str(path)],
        check=False,
        capture_output=True,
        text=True,
    )
    if completed.returncode != 0:
        raise SourceContractError(f"cannot inspect archive architecture: {path.name}")
    return completed.stdout.strip().split()


AARCH64_LANGUAGE_PREFIX = "share/sleigh/specfiles/Ghidra/Processors/AARCH64/data/languages/"


def qualify_package(
    package: Path, governed_package: Path, governed_resources: Path | None = None
) -> dict[str, object]:
    """Compare the source-built seam with governed bytes.

    AArch64 language resources are compared with the MacScope-patched resource closure
    (ThirdParty/SleighNative/AARCH64) when it is supplied; the release-archive package keeps
    the upstream identity (decision D3) and is the comparison for everything else.
    """
    package = package.resolve(strict=True)
    governed_package = governed_package.resolve(strict=True)
    if governed_resources is not None:
        governed_resources = governed_resources.resolve(strict=True)
    analysis = analyze_tree(package)
    critical: dict[str, str] = {}
    for relative in CRITICAL_PACKAGE_PATHS:
        candidate = package / relative
        governed = governed_package / relative
        if governed_resources is not None and relative.startswith(AARCH64_LANGUAGE_PREFIX):
            governed = governed_resources / relative[len(AARCH64_LANGUAGE_PREFIX):]
        if candidate.is_symlink() or not candidate.is_file():
            raise SourceContractError(f"source-built package member is missing: {relative}")
        if governed.is_symlink() or not governed.is_file():
            raise SourceContractError(f"governed comparison member is missing: {relative}")
        critical[relative] = sha256(candidate)
        if relative.startswith("include/") or relative.startswith("share/"):
            if critical[relative] != sha256(governed):
                raise SourceContractError(f"source-built package seam differs from governed bytes: {relative}")
    for archive in (package / "lib/libdecomp.a", package / "lib/libsla.a"):
        if _archive_architectures(archive) != ["arm64"]:
            raise SourceContractError(f"source-built archive is not arm64-only: {archive.name}")
    return {
        "schemaVersion": 1,
        "sourceComponentId": "sleigh-native-source-dcp03b4",
        "sleighRevision": SLEIGH_REVISION,
        "ghidraRevision": GHIDRA_REVISION,
        "package": analysis,
        "criticalFileSha256": critical,
        "architecture": "arm64",
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)
    source_parser = subparsers.add_parser("source")
    source_parser.add_argument("root", type=Path)
    package_parser = subparsers.add_parser("package")
    package_parser.add_argument("root", type=Path)
    package_parser.add_argument("--governed-package", required=True, type=Path)
    package_parser.add_argument("--receipt", type=Path)
    package_parser.add_argument("--governed-resources", type=Path)
    arguments = parser.parse_args()
    try:
        if arguments.command == "source":
            result = verify_source(arguments.root)
        else:
            result = qualify_package(
                arguments.root, arguments.governed_package, arguments.governed_resources
            )
            if arguments.receipt:
                receipt = arguments.receipt
                if receipt.exists() or receipt.is_symlink():
                    raise SourceContractError("receipt destination already exists")
                receipt.parent.mkdir(parents=True, exist_ok=True)
                receipt.write_text(
                    json.dumps(result, sort_keys=True, separators=(",", ":")) + "\n",
                    encoding="utf-8",
                )
        print(json.dumps(result, sort_keys=True))
    except (OSError, SourceContractError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
