#!/usr/bin/env python3
"""Fail-closed DCP-03B4 native SLEIGH package contract.

The ordinary MacScope build does not import or execute this module. It is used
only by the explicit dependency materializer, developer qualification, and
standard-library tests.
"""

from __future__ import annotations

import dataclasses
import hashlib
import json
import os
import re
import stat
from pathlib import Path
from typing import Any, Iterable, Mapping

COMPONENT_ID = "sleigh-native-dcp03b4"
SOURCE_COMPONENT_ID = "sleigh-native-source-dcp03b4"
SANITIZER_SOURCE_COMPONENT_ID = "sleigh-native-sanitizer-source-dcp03b4"
SLEIGH_VERSION = "12.1.2"
SLEIGH_GIT_REVISION = "bfd38a983b4aa53dd386365e1df5ed5499b7e2fb"
GHIDRA_VERSION = "12.1.2"
GHIDRA_GIT_REVISION = "c0f584bf229fffba61b36431f3ce30c0c3e4e682"
SCHEMA_VERSION = 1
SOURCE_SCHEMA_VERSION = 2
SANITIZER_SOURCE_SCHEMA_VERSION = 3
SANITIZER_FLAGS = {
    "address": ("-fsanitize=address", "-fno-omit-frame-pointer"),
    "undefined": ("-fsanitize=undefined", "-fno-sanitize-recover=all"),
}
SANITIZER_ARCHIVES = {
    "sleigh_decomp": "lib/libdecomp.a",
    "sleigh_sla": "lib/libsla.a",
}

SOURCE_MANIFEST_SHA256 = "e5525e857e0a3f88aa7f8550e0d6b1a72ef232eedb61e6b31d24c350420ff1d8"
SLEIGH_SOURCE_GIT_TREE = "20043e94b5933466b0861ad68f07f591f70c0050"
SLEIGH_SOURCE_TREE_SHA256 = "2af879c8587ba6b0913ee53b220f1580c92dd521de7671dc3ece8a750b47e622"
GHIDRA_SOURCE_GIT_TREE = "2dfe30eddeefcd3efc9e49ea58bd725de5bbc4bb"
GHIDRA_SOURCE_TREE_SHA256 = "fdcb64b623e3c881a95f16a29750e83fd124cc08149c347d3e56f58352cbe321"
SOURCE_PATCHES = (
    ("0001-Fix-UBSAN-errors-in-decompiler.patch", "7f83a4bd158490c5aa58d789b6f655ced6a9b309f4e43a4870cd893b3d36f2e5"),
    ("0002-Use-stroull-instead-of-stroul-to-parse-address-offse.patch", "8c5ca9c13c87ca4bd456643912205efb26684ccb19055ac60ebe742300a68f39"),
    ("0003-Ignore-floating-point-test-due-to-compilation-differ.patch", "b4dddb53f41fda93ae9acc633ce1886d2eaa4e8a5328361064633b6733a42a99"),
    ("0004-Allow-positive-or-negative-NAN-in-decompiler-floatin.patch", "ea78812681b8f1dbede305cc7bde716b7cee16a30005bc90e8304fbfb3df80dd"),
    ("0005-decompiler-Fix-strict-weak-ordering-TypePartialEnum.patch", "9dbe5ffc7a105e6c199f4027087b553e619691e2402f43a9357ffdec7f55fc11"),
    ("0006-decompiler-Fix-strict-weak-ordering-PullRecord.patch", "fe52595fc8a2843006f771880e3d49782564770295b4b0a7475ab7d1be435731"),
    ("0007-decompiler-Fix-strict-weak-ordering-compareFinalOrde.patch", "e4b5581e4513e6a76f1ac07999d5c5e42343e125efdbdc753afbda11d1f13c3f"),
    ("0008-Fix-UBSAN-signed-left-shift-errors.patch", "2b8a93f1dbf25c9855a85807e0d0c2cd0836789118e3a2a154e24d4a9c20426d"),
)
SOURCE_BUILD_OPTIONS = (
    "ZERO_AR_DATE=1",
    "SOURCE_DATE_EPOCH=946684800",
    "LC_ALL=C",
    "TZ=UTC",
    "CMAKE_BUILD_TYPE=Release",
    "CMAKE_OSX_ARCHITECTURES=arm64",
    "CMAKE_OSX_DEPLOYMENT_TARGET=27.0",
    "BUILD_SHARED_LIBS=OFF",
    "sleigh_DEVELOPER_MODE=OFF",
    "sleigh_BUILD_TOOLS=OFF",
    "sleigh_BUILD_SLEIGHSPECS=OFF",
    "sleigh_BUILD_SUPPORT=OFF",
    "sleigh_BUILD_EXTRATOOLS=OFF",
    "sleigh_BUILD_EXAMPLE=OFF",
    "FETCHCONTENT_SOURCE_DIR_GHIDRASOURCE=<verified-external-source-copy>",
    "FETCHCONTENT_FULLY_DISCONNECTED=ON",
    "FETCHCONTENT_UPDATES_DISCONNECTED=ON",
    "FETCHCONTENT_TRY_FIND_PACKAGE_MODE=NEVER",
    "CMAKE_FIND_USE_PACKAGE_REGISTRY=FALSE",
    "CMAKE_FIND_USE_SYSTEM_PACKAGE_REGISTRY=FALSE",
)

MAX_FILES = 100_000
MAX_TOTAL_BYTES = 8 * 1024 * 1024 * 1024
MAX_FILE_BYTES = 2 * 1024 * 1024 * 1024
MAX_TEXT_BYTES = 16 * 1024 * 1024
MAX_PATH_BYTES = 4096
HEX64 = re.compile(r"^[0-9a-f]{64}$")


class PackageContractError(RuntimeError):
    """Raised when a package or its materialization record is untrusted."""


class DuplicateJSONKey(ValueError):
    pass


@dataclasses.dataclass(frozen=True)
class ArtifactIdentity:
    platform: str
    filename: str
    url: str
    sha256: str

    def as_json(self) -> dict[str, str]:
        return dataclasses.asdict(self)


APPROVED_ARTIFACTS: dict[str, ArtifactIdentity] = {
    "macos-arm64": ArtifactIdentity(
        platform="macos-arm64",
        filename="macOS-sleigh-12.1.2-1.arm64.tar.gz",
        url=(
            "https://github.com/lifting-bits/sleigh/releases/download/v12.1.2/"
            "macOS-sleigh-12.1.2-1.arm64.tar.gz"
        ),
        sha256="e1391c811de7b2d79c9e8a1f6f74cd9ade23baf55deebd75c626a3152e5e451a",
    ),
    "linux-x86_64": ArtifactIdentity(
        platform="linux-x86_64",
        filename="Linux-sleigh-12.1.2-1.x86_64.tar.gz",
        url=(
            "https://github.com/lifting-bits/sleigh/releases/download/v12.1.2/"
            "Linux-sleigh-12.1.2-1.x86_64.tar.gz"
        ),
        sha256="7539dd630b7069b372d8fbe9be8e29ef4ca9c7ce2945c2a3009d43ab98b12ea4",
    ),
}
APPROVED_BY_FILENAME = {item.filename: item for item in APPROVED_ARTIFACTS.values()}

_REQUIRED_HEADERS = (
    "libdecomp.hh",
    "sleigh_arch.hh",
    "loadimage.hh",
    "funcdata.hh",
    "heritage.hh",
    "varnode.hh",
    "prettyprint.hh",
    "printc.hh",
)
_REQUIRED_SPEC_SUFFIXES = (".sla", ".ldefs", ".pspec", ".cspec")
_FORBIDDEN_BINARY_SUFFIXES = (".jar", ".class")
_FORBIDDEN_PATH_COMPONENTS = {"gpl"}

APPLE_SILICON_CRITICAL_FILE_RELATIVE_PATHS = (
    "share/sleigh/specfiles/Ghidra/Processors/AARCH64/data/languages/AppleSilicon.ldefs",
    "share/sleigh/specfiles/Ghidra/Processors/AARCH64/data/languages/AARCH64_AppleSilicon.sla",
    "share/sleigh/specfiles/Ghidra/Processors/AARCH64/data/languages/AARCH64.pspec",
    "share/sleigh/specfiles/Ghidra/Processors/AARCH64/data/languages/AARCH64_apple.cspec",
)

PACKAGE_IDENTITY_COMPARISON_FIELDS = (
    "cmakeConfigRelativePath",
    "processorSpecRelativeRoot",
    "decompilerLibraryRelativePath",
    "sleighLibraryRelativePath",
    "fileCount",
    "totalBytes",
    "treeSha256",
)
PACKAGE_IDENTITY_SEPARATELY_VALIDATED_FIELDS = (
    "relativeRoot",
    "criticalFileSha256",
)


def _json_without_duplicate_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    value: dict[str, Any] = {}
    for key, item in pairs:
        if key in value:
            raise DuplicateJSONKey(key)
        value[key] = item
    return value


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        while chunk := stream.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def _ordinary_directory(path: Path, label: str) -> Path:
    try:
        metadata = path.lstat()
    except OSError as error:
        raise PackageContractError(f"{label} is missing or inaccessible: {error}") from error
    if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISDIR(metadata.st_mode):
        raise PackageContractError(f"{label} must be an ordinary directory")
    return path.resolve(strict=True)


def _ordinary_file(path: Path, label: str, maximum: int = MAX_FILE_BYTES) -> Path:
    try:
        metadata = path.lstat()
    except OSError as error:
        raise PackageContractError(f"{label} is missing or inaccessible: {error}") from error
    if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISREG(metadata.st_mode):
        raise PackageContractError(f"{label} must be an ordinary file")
    if metadata.st_size > maximum:
        raise PackageContractError(f"{label} exceeds the fixed size bound")
    return path


def _read_text(path: Path, label: str) -> str:
    path = _ordinary_file(path, label, MAX_TEXT_BYTES)
    try:
        return path.read_text(encoding="utf-8")
    except UnicodeDecodeError as error:
        raise PackageContractError(f"{label} must be UTF-8") from error


def _walk_ordinary_files(root: Path) -> tuple[Path, ...]:
    root = _ordinary_directory(root, "package root")
    files: list[Path] = []
    total = 0
    for current, directories, filenames in os.walk(root, topdown=True, followlinks=False):
        current_path = Path(current)
        safe_directories: list[str] = []
        for name in sorted(directories, key=os.fsencode):
            child = current_path / name
            metadata = child.lstat()
            if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISDIR(metadata.st_mode):
                raise PackageContractError("package contains a non-directory or linked directory")
            relative = child.relative_to(root).as_posix()
            if not relative or len(relative.encode("utf-8")) > MAX_PATH_BYTES or "\x00" in relative:
                raise PackageContractError("package contains an invalid path")
            if any(part.casefold() in _FORBIDDEN_PATH_COMPONENTS for part in Path(relative).parts):
                raise PackageContractError("package contains a forbidden GPL path component")
            safe_directories.append(name)
        directories[:] = safe_directories
        if not directories and not filenames:
            raise PackageContractError("package contains an empty directory")
        for name in sorted(filenames, key=os.fsencode):
            child = current_path / name
            metadata = child.lstat()
            if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISREG(metadata.st_mode):
                raise PackageContractError("package contains a link or non-regular file")
            relative = child.relative_to(root).as_posix()
            if not relative or len(relative.encode("utf-8")) > MAX_PATH_BYTES or "\x00" in relative:
                raise PackageContractError("package contains an invalid path")
            if any(part.casefold() in _FORBIDDEN_PATH_COMPONENTS for part in Path(relative).parts):
                raise PackageContractError("package contains a forbidden GPL path component")
            if child.suffix.casefold() in _FORBIDDEN_BINARY_SUFFIXES:
                raise PackageContractError("package contains a Java runtime artifact")
            if metadata.st_size > MAX_FILE_BYTES:
                raise PackageContractError("package member exceeds the fixed file-size bound")
            total += metadata.st_size
            if total > MAX_TOTAL_BYTES:
                raise PackageContractError("package exceeds the fixed total-size bound")
            files.append(child)
            if len(files) > MAX_FILES:
                raise PackageContractError("package exceeds the fixed file-count bound")
    if not files:
        raise PackageContractError("package contains no files")
    return tuple(files)


def _install_prefix_for_config(scan_root: Path, config: Path) -> Path:
    relative = config.relative_to(scan_root)
    parts = relative.parts
    suffix = ("cmake", "sleigh", "sleighConfig.cmake")
    candidates: list[int] = []
    for index in range(1, len(parts) - 2):
        if tuple(parts[index : index + 3]) == suffix and parts[index - 1] in {"lib", "lib64"}:
            candidates.append(index - 1)
    if len(candidates) != 1:
        raise PackageContractError("sleighConfig.cmake is outside the canonical lib/cmake layout")
    prefix = scan_root.joinpath(*parts[: candidates[0]])
    return prefix.resolve(strict=True)


def discover_install_prefix(extraction_root: Path) -> Path:
    """Return the unique install prefix and reject files outside it."""

    root = _ordinary_directory(extraction_root, "extraction root")
    files = _walk_ordinary_files(root)
    configs = [path for path in files if path.name == "sleighConfig.cmake"]
    if len(configs) != 1:
        raise PackageContractError(
            f"expected exactly one sleighConfig.cmake, found {len(configs)}"
        )
    prefix = _install_prefix_for_config(root, configs[0])
    for path in files:
        try:
            path.relative_to(prefix)
        except ValueError as error:
            raise PackageContractError("archive contains files outside the SLEIGH install prefix") from error
    return prefix


def _relative(prefix: Path, path: Path) -> str:
    return path.relative_to(prefix).as_posix()


def _require_unique_file(paths: Iterable[Path], predicate: Any, label: str) -> Path:
    matches = [path for path in paths if predicate(path)]
    if len(matches) != 1:
        raise PackageContractError(f"expected exactly one {label}, found {len(matches)}")
    return matches[0]


def _require_token(text: str, token: str, label: str) -> None:
    if token not in text:
        raise PackageContractError(f"{label} does not declare {token}")


def analyze_package(
    package_root: Path,
    *,
    require_root_prefix: bool = True,
    _digest_evidence: Mapping[str, tuple[int, str]] | None = None,
) -> dict[str, Any]:
    """Validate one extracted installation and return its canonical identity."""

    root = _ordinary_directory(package_root, "package root")
    apple_silicon_critical_paths: list[Path] = []
    for relative_path in APPLE_SILICON_CRITICAL_FILE_RELATIVE_PATHS:
        path = _ordinary_file(
            root / relative_path,
            f"required Apple Silicon profile resource {relative_path}",
        )
        resolved = path.resolve(strict=True)
        if not resolved.is_relative_to(root):
            raise PackageContractError(
                f"required Apple Silicon profile resource {relative_path} escapes the package root"
            )
        apple_silicon_critical_paths.append(path)
    files = _walk_ordinary_files(root)
    configs = [path for path in files if path.name == "sleighConfig.cmake"]
    if len(configs) != 1:
        raise PackageContractError(
            f"expected exactly one sleighConfig.cmake, found {len(configs)}"
        )
    prefix = _install_prefix_for_config(root, configs[0])
    if require_root_prefix and prefix != root:
        raise PackageContractError("materialized package root must be the SLEIGH install prefix")

    prefix_files = tuple(path for path in files if path.is_relative_to(prefix))
    if len(prefix_files) != len(files):
        raise PackageContractError("package contains files outside the install prefix")

    expected_relatives = {_relative(prefix, path) for path in prefix_files}
    if _digest_evidence is not None:
        if set(_digest_evidence) != expected_relatives:
            raise PackageContractError(
                "descriptor-bound digest evidence does not cover the exact package file set"
            )
        for relative, record in _digest_evidence.items():
            if (
                not isinstance(record, tuple)
                or len(record) != 2
                or not isinstance(record[0], int)
                or record[0] < 0
                or not isinstance(record[1], str)
                or HEX64.fullmatch(record[1]) is None
            ):
                raise PackageContractError(
                    "descriptor-bound digest evidence has an invalid record"
                )

    def digest_for(path: Path, size: int) -> str:
        if _digest_evidence is None:
            return _sha256(path)
        relative = _relative(prefix, path)
        recorded_size, digest = _digest_evidence[relative]
        if recorded_size != size:
            raise PackageContractError(
                "descriptor-bound digest evidence has an unexpected file size"
            )
        return digest

    config = configs[0]
    config_dir = config.parent
    required_cmake = (
        config_dir / "sleighConfigVersion.cmake",
        config_dir / "sleighTargets.cmake",
        config_dir / "specfiles.cmake",
        config_dir / "modules" / "sleighCompile.cmake",
    )
    for path in required_cmake:
        _ordinary_file(path, f"required CMake package file {path.name}", MAX_TEXT_BYTES)

    config_text = _read_text(config, "sleighConfig.cmake")
    version_text = _read_text(config_dir / "sleighConfigVersion.cmake", "sleighConfigVersion.cmake")
    targets_text = _read_text(config_dir / "sleighTargets.cmake", "sleighTargets.cmake")
    specfiles_text = _read_text(config_dir / "specfiles.cmake", "specfiles.cmake")
    _require_token(config_text, "find_dependency(ZLIB)", "sleighConfig.cmake")
    _require_token(config_text, "sleighTargets.cmake", "sleighConfig.cmake")
    _require_token(config_text, "specfiles.cmake", "sleighConfig.cmake")
    _require_token(version_text, f'set(PACKAGE_VERSION "{SLEIGH_VERSION}")', "sleighConfigVersion.cmake")
    _require_token(specfiles_text, "sleigh_INSTALL_SPECDIR", "specfiles.cmake")
    _require_token(targets_text, "sleigh::decomp", "sleighTargets.cmake")
    _require_token(targets_text, "sleigh::sla", "sleighTargets.cmake")

    include_root = prefix / "include" / "sleigh" / "ghidra"
    _ordinary_directory(include_root, "Ghidra public-header directory")
    header_paths: list[Path] = []
    for name in _REQUIRED_HEADERS:
        header_paths.append(_ordinary_file(include_root / name, f"required header {name}", MAX_TEXT_BYTES))

    library_candidates = [
        path
        for path in prefix_files
        if path.parent.name in {"lib", "lib64"}
        and (
            path.suffix in {".a", ".dylib", ".so"}
            or ".so." in path.name
        )
    ]
    decomp_library = _require_unique_file(
        library_candidates,
        lambda path: path.name in {"libdecomp.a", "libdecomp.dylib", "decomp.lib"}
        or path.name.startswith("libdecomp.so"),
        "native decompiler library",
    )
    sla_library = _require_unique_file(
        library_candidates,
        lambda path: path.name in {"libsla.a", "libsla.dylib", "sla.lib"}
        or path.name.startswith("libsla.so"),
        "native SLEIGH library",
    )

    expected_spec_root = (
        prefix
        / "share"
        / "sleigh"
        / "specfiles"
        / "Ghidra"
        / "Processors"
        / "AARCH64"
        / "data"
        / "languages"
    )
    spec_root = _ordinary_directory(expected_spec_root, "AArch64 processor-specification directory")
    spec_files = tuple(path for path in prefix_files if path.is_relative_to(spec_root))
    required_specs: dict[str, list[Path]] = {}
    for suffix in _REQUIRED_SPEC_SUFFIXES:
        matches = [path for path in spec_files if path.suffix.casefold() == suffix]
        if not matches:
            raise PackageContractError(f"AArch64 processor resources contain no {suffix} file")
        required_specs[suffix] = sorted(matches, key=lambda item: os.fsencode(_relative(prefix, item)))
    if not any("aarch64" in path.stem.casefold() for path in required_specs[".sla"]):
        raise PackageContractError("AArch64 processor resources contain no AARCH64 .sla file")

    tree_digest = hashlib.sha256()
    total_bytes = 0
    for path in sorted(prefix_files, key=lambda item: os.fsencode(_relative(prefix, item))):
        relative = _relative(prefix, path)
        size = path.stat().st_size
        digest = digest_for(path, size)
        total_bytes += size
        tree_digest.update(relative.encode("utf-8"))
        tree_digest.update(b"\0")
        tree_digest.update(str(size).encode("ascii"))
        tree_digest.update(b"\0")
        tree_digest.update(digest.encode("ascii"))
        tree_digest.update(b"\0")

    critical_paths = [
        config,
        *required_cmake,
        *header_paths,
        decomp_library,
        sla_library,
        *[paths[0] for paths in required_specs.values()],
        *apple_silicon_critical_paths,
    ]
    critical = {
        _relative(prefix, path): digest_for(path, path.stat().st_size)
        for path in sorted(set(critical_paths), key=lambda item: os.fsencode(_relative(prefix, item)))
    }

    return {
        "cmakeConfigRelativePath": _relative(prefix, config),
        "processorSpecRelativeRoot": _relative(prefix, spec_root),
        "decompilerLibraryRelativePath": _relative(prefix, decomp_library),
        "sleighLibraryRelativePath": _relative(prefix, sla_library),
        "fileCount": len(prefix_files),
        "totalBytes": total_bytes,
        "treeSha256": tree_digest.hexdigest(),
        "criticalFileSha256": critical,
    }


def approved_artifact_for_path(path: Path) -> ArtifactIdentity:
    path = _ordinary_file(path, "release artifact")
    approved = APPROVED_BY_FILENAME.get(path.name)
    if approved is None:
        raise PackageContractError("release artifact name is not approved for DCP-03B4")
    observed = _sha256(path)
    if observed != approved.sha256:
        raise PackageContractError("release artifact SHA-256 does not match the immutable pin")
    return approved


def materialization_value(artifact: ArtifactIdentity, analysis: dict[str, Any]) -> dict[str, Any]:
    return {
        "schemaVersion": SCHEMA_VERSION,
        "componentId": COMPONENT_ID,
        "sleighVersion": SLEIGH_VERSION,
        "sleighGitRevision": SLEIGH_GIT_REVISION,
        "ghidraVersion": GHIDRA_VERSION,
        "ghidraGitRevision": GHIDRA_GIT_REVISION,
        "artifact": artifact.as_json(),
        "package": {"relativeRoot": "package", **analysis},
    }


def _source_static_evidence(sanitizer: str = "none") -> dict[str, Any]:
    if sanitizer not in {"none", *SANITIZER_FLAGS}:
        raise PackageContractError("unsupported sanitizer profile")
    options = list(SOURCE_BUILD_OPTIONS)
    if sanitizer != "none":
        options += [
            "CMAKE_EXPORT_COMPILE_COMMANDS=ON",
            "CMAKE_OSX_SYSROOT=<verified-xcode-sdk>",
            "CMAKE_CXX_FLAGS=" + " ".join(SANITIZER_FLAGS[sanitizer]),
            "CMAKE_CXX_FLAGS_RELEASE=-O1 -g -DNDEBUG",
            "CMAKE_EXE_LINKER_FLAGS=-fsanitize=" + sanitizer,
        ]
    return {
        "sourceManifestSha256": SOURCE_MANIFEST_SHA256,
        "sleighGitTree": SLEIGH_SOURCE_GIT_TREE,
        "sleighTreeSha256": SLEIGH_SOURCE_TREE_SHA256,
        "ghidraGitTree": GHIDRA_SOURCE_GIT_TREE,
        "ghidraTreeSha256": GHIDRA_SOURCE_TREE_SHA256,
        "patches": [
            {"path": path, "sha256": digest}
            for path, digest in SOURCE_PATCHES
        ],
        "buildOptions": options,
    }


def _validate_tool_identity(value: Any, label: str) -> dict[str, str]:
    record = _require_exact_keys(value, {"path", "sha256", "version"}, label)
    path = record["path"]
    digest = record["sha256"]
    version = record["version"]
    if (
        not isinstance(path, str)
        or not Path(path).is_absolute()
        or len(path.encode("utf-8")) > MAX_PATH_BYTES
        or any(character in path for character in ("\r", "\n", "\x00"))
    ):
        raise PackageContractError(f"{label}.path must be a bounded absolute path")
    if not isinstance(digest, str) or HEX64.fullmatch(digest) is None:
        raise PackageContractError(f"{label}.sha256 must be lowercase SHA-256")
    if (
        not isinstance(version, str)
        or not version
        or len(version.encode("utf-8")) > 4096
        or any(character in version for character in ("\r", "\n", "\x00"))
    ):
        raise PackageContractError(f"{label}.version must be bounded single-line text")
    if label == "sourceBuild.toolchain.compiler" and not version.startswith(
        "Apple clang version 21."
    ):
        raise PackageContractError("source compiler is outside the Xcode 27 toolchain line")
    if label == "sourceBuild.toolchain.cmake" and re.fullmatch(
        r"cmake version [0-9]+\.[0-9]+\.[0-9]+", version
    ) is None:
        raise PackageContractError("source CMake version evidence is unsupported")
    if label == "sourceBuild.toolchain.ninja" and re.fullmatch(
        r"[0-9]+\.[0-9]+(?:\.[0-9]+)?", version
    ) is None:
        raise PackageContractError("source Ninja version evidence is unsupported")
    return record


def _validate_instrumentation(value: Any, sanitizer: str) -> dict[str, Any]:
    record = _require_exact_keys(value, {
        "profile", "compileCommandsSha256", "sdkRoot", "sdkSettingsSha256",
        "translationUnitCounts", "archiveSha256",
    }, "sourceBuild.instrumentation")
    if record["profile"] != sanitizer or sanitizer not in SANITIZER_FLAGS:
        raise PackageContractError("instrumentation profile does not match the sanitizer")
    for key in ("compileCommandsSha256", "sdkSettingsSha256"):
        if not isinstance(record[key], str) or HEX64.fullmatch(record[key]) is None:
            raise PackageContractError(f"instrumentation.{key} must be lowercase SHA-256")
    sdk = record["sdkRoot"]
    if (not isinstance(sdk, str) or not Path(sdk).is_absolute()
            or len(sdk.encode("utf-8")) > MAX_PATH_BYTES
            or any(c in sdk for c in ("\r", "\n", "\x00"))):
        raise PackageContractError("instrumentation.sdkRoot must be a bounded absolute path")
    counts = _require_exact_keys(record["translationUnitCounts"], set(SANITIZER_ARCHIVES),
                                 "instrumentation.translationUnitCounts")
    if any(type(count) is not int or not 0 < count <= MAX_FILES for count in counts.values()):
        raise PackageContractError("instrumentation translation unit counts must be positive integers")
    archives = _require_exact_keys(record["archiveSha256"], set(SANITIZER_ARCHIVES.values()),
                                   "instrumentation.archiveSha256")
    if any(not isinstance(digest, str) or HEX64.fullmatch(digest) is None
           for digest in archives.values()):
        raise PackageContractError("instrumentation archive digests must be lowercase SHA-256")
    return record


def _validate_source_build(value: Any, sanitizer: str = "none") -> dict[str, Any]:
    static = _source_static_evidence(sanitizer)
    extra = {"instrumentation"} if sanitizer != "none" else set()
    record = _require_exact_keys(value, set(static) | {"toolchain"} | extra, "sourceBuild")
    for key, expected in static.items():
        if record[key] != expected:
            raise PackageContractError(f"sourceBuild.{key} does not match the frozen contract")
    toolchain = _require_exact_keys(
        record["toolchain"], {"compiler", "cmake", "ninja"}, "sourceBuild.toolchain"
    )
    for name in ("compiler", "cmake", "ninja"):
        _validate_tool_identity(toolchain[name], f"sourceBuild.toolchain.{name}")
    if sanitizer != "none":
        _validate_instrumentation(record["instrumentation"], sanitizer)
    return record


def source_materialization_value(
    analysis: dict[str, Any],
    toolchain: dict[str, Any],
    *,
    sanitizer: str = "none",
    instrumentation: dict[str, Any] | None = None,
) -> dict[str, Any]:
    source_build = {**_source_static_evidence(sanitizer), "toolchain": toolchain}
    if sanitizer != "none":
        source_build["instrumentation"] = instrumentation
    elif instrumentation is not None:
        raise PackageContractError("production source materialization cannot carry sanitizer evidence")
    _validate_source_build(source_build, sanitizer)
    if sanitizer != "none" and any(
        analysis["criticalFileSha256"].get(relative) != digest
        for relative, digest in instrumentation["archiveSha256"].items()
    ):
        raise PackageContractError("instrumented archives do not match package critical file identity")
    return {
        "schemaVersion": SOURCE_SCHEMA_VERSION if sanitizer == "none" else SANITIZER_SOURCE_SCHEMA_VERSION,
        "componentId": SOURCE_COMPONENT_ID if sanitizer == "none" else SANITIZER_SOURCE_COMPONENT_ID,
        **({"sanitizer": sanitizer} if sanitizer != "none" else {}),
        "sleighVersion": SLEIGH_VERSION,
        "sleighGitRevision": SLEIGH_GIT_REVISION,
        "ghidraVersion": GHIDRA_VERSION,
        "ghidraGitRevision": GHIDRA_GIT_REVISION,
        "sourceBuild": source_build,
        "package": {"relativeRoot": "package", **analysis},
    }


def write_materialization(
    package_root: Path,
    artifact_path: Path,
    destination: Path,
) -> dict[str, Any]:
    artifact = approved_artifact_for_path(artifact_path)
    analysis = analyze_package(package_root)
    value = materialization_value(artifact, analysis)
    payload = json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n"
    destination.parent.mkdir(parents=True, exist_ok=True)
    if destination.exists() or destination.is_symlink():
        raise PackageContractError("materialization record destination already exists")
    descriptor = os.open(
        destination,
        os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0),
        0o644,
    )
    with os.fdopen(descriptor, "w", encoding="utf-8", newline="\n") as stream:
        stream.write(payload)
        stream.flush()
        os.fsync(stream.fileno())
    return value


def write_source_materialization(
    package_root: Path,
    toolchain: dict[str, Any],
    destination: Path,
    *,
    sanitizer: str = "none",
    instrumentation: dict[str, Any] | None = None,
) -> dict[str, Any]:
    value = source_materialization_value(analyze_package(package_root), toolchain,
                                         sanitizer=sanitizer, instrumentation=instrumentation)
    payload = json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n"
    destination.parent.mkdir(parents=True, exist_ok=True)
    if destination.exists() or destination.is_symlink():
        raise PackageContractError("materialization record destination already exists")
    descriptor = os.open(
        destination,
        os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0),
        0o644,
    )
    with os.fdopen(descriptor, "w", encoding="utf-8", newline="\n") as stream:
        stream.write(payload)
        stream.flush()
        os.fsync(stream.fileno())
    return value


def _require_exact_keys(value: Any, keys: set[str], label: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise PackageContractError(f"{label} must be an object")
    if set(value) != keys:
        raise PackageContractError(f"{label} has a missing or unknown field")
    return value


def _load_manifest(path: Path) -> dict[str, Any]:
    text = _read_text(path, "MATERIALIZATION.json")
    try:
        value = json.loads(text, object_pairs_hook=_json_without_duplicate_keys)
    except DuplicateJSONKey as error:
        raise PackageContractError(f"MATERIALIZATION.json contains duplicate key: {error.args[0]}") from error
    except json.JSONDecodeError as error:
        raise PackageContractError("MATERIALIZATION.json is not canonical JSON") from error
    canonical = json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n"
    if canonical != text:
        raise PackageContractError("MATERIALIZATION.json is not canonically serialized")
    return value


def _diagnostic_component_id(value: Any) -> str:
    if not isinstance(value, str):
        return f"<{type(value).__name__}>"
    bounded = value if len(value) <= 128 else value[:128] + "…"
    return json.dumps(bounded, ensure_ascii=True)


def _package_identity_differences(
    recorded: dict[str, Any],
    observed: dict[str, Any],
) -> list[str]:
    details: list[str] = []
    for field in PACKAGE_IDENTITY_COMPARISON_FIELDS:
        recorded_value = recorded[field]
        observed_value = observed[field]
        if recorded_value == observed_value:
            continue
        if field in {"fileCount", "totalBytes"}:
            if type(recorded_value) is int and type(observed_value) is int:
                details.append(
                    f"{field} (recorded={recorded_value}, observed={observed_value}, "
                    f"delta={observed_value - recorded_value:+d})"
                )
            else:
                details.append(
                    f"{field} (recorded type={type(recorded_value).__name__}, "
                    f"observed type={type(observed_value).__name__})"
                )
            continue
        details.append(field)
    return details


def _overlay_package_identity(
    root: Path, manifest: dict[str, Any], package: dict[str, Any]
) -> dict[str, Any]:
    """Bind the producer's separate overlay identity to its archive baseline.

    Keep MATERIALIZATION.json as the original archive identity. Only the three
    complete-package summary fields can differ for the recorded resource overlay;
    the analyzer still enforces every ordinary-file and package-layout constraint.
    """
    label = "PATCHED_RESOURCES.json"
    try:
        record = json.loads(
            _read_text(root / label, label),
            object_pairs_hook=_json_without_duplicate_keys,
        )
    except (json.JSONDecodeError, DuplicateJSONKey) as error:
        raise PackageContractError(f"{label} is malformed or has duplicate keys") from error
    if (not isinstance(record, dict) or type(record.get("schemaVersion")) is not int
            or record.get("schemaVersion") != 1 or record.get(
        "componentId"
    ) != "sleigh-native-dcp03b4-aarch64-patched-resources"):
        raise PackageContractError(f"{label} has an unexpected resource contract")
    baseline = record.get("baseline")
    patched = record.get("patched")
    if (manifest["schemaVersion"] != SCHEMA_VERSION
            or not isinstance(baseline, dict) or not isinstance(patched, dict)
            or baseline.get("artifactSha256") != manifest["artifact"]["sha256"]
            or baseline.get("packageTreeSha256") != package["treeSha256"]):
        raise PackageContractError(f"{label} does not match the archive baseline")
    expected = dict(package)
    for field, record_field in (
        ("treeSha256", "packageTreeSha256WithResourceOverlay"),
        ("fileCount", "packageFileCountWithResourceOverlay"),
        ("totalBytes", "packageTotalBytesWithResourceOverlay"),
    ):
        value = patched.get(record_field)
        if field == "treeSha256":
            valid = isinstance(value, str) and HEX64.fullmatch(value) is not None
        else:
            valid = type(value) is int and value > 0
        if not valid:
            raise PackageContractError(f"{label} has an invalid {record_field}")
        expected[field] = value
    return expected


def verify_materialization(
    materialization_root: Path,
    *,
    expected_sanitizer: str = "none",
    _package_digest_evidence: Mapping[str, tuple[int, str]] | None = None,
) -> dict[str, Any]:
    if expected_sanitizer not in {"none", *SANITIZER_FLAGS}:
        raise PackageContractError("unsupported expected sanitizer profile")
    root = _ordinary_directory(materialization_root, "materialization root")
    observed_items = {path.name for path in root.iterdir()}
    baseline_items = {"MATERIALIZATION.json", "package"}
    has_overlay = observed_items == baseline_items | {"PATCHED_RESOURCES.json"}
    if observed_items != baseline_items and not has_overlay:
        raise PackageContractError("materialization root contains unexpected entries")
    value = _load_manifest(root / "MATERIALIZATION.json")
    schema_version = value.get("schemaVersion")
    if schema_version == SCHEMA_VERSION:
        identity_field = "artifact"
        expected_component_id = COMPONENT_ID
    elif schema_version == SOURCE_SCHEMA_VERSION:
        identity_field = "sourceBuild"
        expected_component_id = SOURCE_COMPONENT_ID
    elif schema_version == SANITIZER_SOURCE_SCHEMA_VERSION:
        identity_field = "sourceBuild"
        expected_component_id = SANITIZER_SOURCE_COMPONENT_ID
    else:
        raise PackageContractError("MATERIALIZATION.json has an unexpected schemaVersion")
    sanitizer = value.get("sanitizer", "none")
    if (sanitizer != expected_sanitizer
            or (schema_version == SANITIZER_SOURCE_SCHEMA_VERSION) != (expected_sanitizer != "none")):
        raise PackageContractError("materialization does not match the expected sanitizer profile")
    _require_exact_keys(
        value,
        {
            "schemaVersion",
            "componentId",
            "sleighVersion",
            "sleighGitRevision",
            "ghidraVersion",
            "ghidraGitRevision",
            identity_field,
            "package",
        } | ({"sanitizer"} if schema_version == SANITIZER_SOURCE_SCHEMA_VERSION else set()),
        "materialization record",
    )
    if value["componentId"] != expected_component_id:
        raise PackageContractError(
            "MATERIALIZATION.json componentId mismatch: "
            f"expected {json.dumps(expected_component_id)}, "
            f"supplied {_diagnostic_component_id(value['componentId'])}"
        )
    constants = {
        "schemaVersion": schema_version,
        "sleighVersion": SLEIGH_VERSION,
        "sleighGitRevision": SLEIGH_GIT_REVISION,
        "ghidraVersion": GHIDRA_VERSION,
        "ghidraGitRevision": GHIDRA_GIT_REVISION,
    }
    for key, expected in constants.items():
        if value[key] != expected:
            raise PackageContractError(f"MATERIALIZATION.json has an unexpected {key}")

    if schema_version == SCHEMA_VERSION:
        artifact_value = _require_exact_keys(
            value["artifact"], {"platform", "filename", "url", "sha256"}, "artifact"
        )
        if not isinstance(artifact_value.get("filename"), str):
            raise PackageContractError("artifact filename must be text")
        approved = APPROVED_BY_FILENAME.get(artifact_value["filename"])
        if approved is None or artifact_value != approved.as_json():
            raise PackageContractError("materialization artifact identity is not approved")
    else:
        _validate_source_build(value["sourceBuild"], sanitizer)

    package_value = _require_exact_keys(
        value["package"],
        {
            "relativeRoot",
            "cmakeConfigRelativePath",
            "processorSpecRelativeRoot",
            "decompilerLibraryRelativePath",
            "sleighLibraryRelativePath",
            "fileCount",
            "totalBytes",
            "treeSha256",
            "criticalFileSha256",
        },
        "package",
    )
    if package_value["relativeRoot"] != "package":
        raise PackageContractError("package.relativeRoot must be package")
    critical_value = package_value["criticalFileSha256"]
    if not isinstance(critical_value, dict):
        raise PackageContractError("package.criticalFileSha256 must be an object")
    expected_package = (
        _overlay_package_identity(root, value, package_value) if has_overlay else package_value
    )
    package_root = (root / "package").resolve(strict=True)
    analysis = analyze_package(
        package_root,
        _digest_evidence=_package_digest_evidence,
    )
    observed_package = {"relativeRoot": "package", **analysis}
    differences = _package_identity_differences(expected_package, observed_package)
    if differences:
        raise PackageContractError(
            "materialized package differs from its recorded identity: "
            + "; ".join(differences)
        )
    if sanitizer != "none":
        archives = value["sourceBuild"]["instrumentation"]["archiveSha256"]
        if any(analysis["criticalFileSha256"].get(relative) != digest
               or critical_value.get(relative) != digest for relative, digest in archives.items()):
            raise PackageContractError("instrumented archives do not match package critical file identity")
    return value


def canonical_json(value: Any) -> str:
    return json.dumps(value, sort_keys=True, separators=(",", ":"))
