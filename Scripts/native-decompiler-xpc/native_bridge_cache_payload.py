#!/usr/bin/env python3
"""Path-free cache payload for the native decompiler bridge archive (R11.2).

``build_native_bridge.sh`` produces a CMake build tree whose ``CMakeCache.txt``
and ``macscope-native-decompiler-link-inputs.xcfilelist`` name absolute local
paths (source, build, SLEIGH materialization and SDK roots). Neither may enter
the shared dependency cache key or entry. This helper is the single owner of
the conversion between that build tree and the cached payload:

``extract``  build tree -> payload. Copies only the contract archive, the
             generated build-identity header and the link-probe inspection,
             and projects the four configuration facts the golden check reads
             from ``CMakeCache.txt`` into ``CONFIGURATION.json``. Every payload
             byte is scanned for local-path markers and rejected if any appear.
``verify``   domain verifier of a payload or read-only view against the
             current wrapper source identity and the SLEIGH materialization.
``stage``    verified view -> ``$MACSCOPE_NATIVE_DECOMPILER_BUILD_ROOT``. Copies
             the files (never links them; the golden requires singly linked
             files), regenerates a projection ``CMakeCache.txt`` from
             ``CONFIGURATION.json`` and regenerates the link-inputs list from
             the consumer's own local roots.
``clear-projection``
             before a local CMake build, remove a projection ``CMakeCache.txt``
             so CMake configures a real build tree.

Routine Debug only (``dev_dependency_cache.py --component native-bridge``).
Release, the qualifier and Gate F keep building the bridge from source.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True

SCHEMA_VERSION = 1
ARCHIVE = "libmacscope_native_decompiler_contract.a"
IDENTITY = "generated/MacScopeNativeDecompiler/GhidraBuildIdentity.hpp"
INSPECTION = "macscope-native-decompiler-link-probe-inspection.txt"
CONFIGURATION = "CONFIGURATION.json"
PAYLOAD_FILES = (ARCHIVE, CONFIGURATION, IDENTITY, INSPECTION)
LINK_INPUTS = "macscope-native-decompiler-link-inputs.xcfilelist"
PROJECTION_MARKER = "# MacScope dev dependency cache projection: not a CMake build tree."
# CMakeCache entries the golden check reads, in the projection's order.
CMAKE_FACTS = (
    ("CMAKE_OSX_ARCHITECTURES", "STRING", "arm64"),
    ("CMAKE_OSX_DEPLOYMENT_TARGET", "STRING", "27.0"),
    ("MACSCOPE_ENABLE_GHIDRA_PROVIDER", "BOOL", "ON"),
    ("MACSCOPE_GHIDRA_PROVIDER_RELOCATABLE_MATERIALIZATION", "BOOL", "ON"),
)
WRAPPER_FACT = "MACSCOPE_NATIVE_DECOMPILER_WRAPPER_GIT_REVISION"
HEX = re.compile(r"[0-9a-f]{64}|[0-9a-f]{40}")
# Generic local-path markers; the caller's own roots are added at run time.
FORBIDDEN_MARKERS = (b"/Users/", b"/home/", b"/private/tmp", b"/private/var/folders", b"DerivedData", b".noindex")
SCRIPT = Path(__file__).resolve()


class PayloadError(RuntimeError):
    pass


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def ordinary(path: Path, label: str) -> Path:
    try:
        metadata = path.lstat()
    except FileNotFoundError as error:
        raise PayloadError(f"{label} is missing") from error
    if not stat.S_ISREG(metadata.st_mode):
        raise PayloadError(f"{label} is not an ordinary file")
    return path


def sdk_file(path: Path, sdk_root: Path, label: str) -> Path:
    """An SDK input that may be a symlink (the SDK ships libz.tbd -> libz.1.tbd), provided
    it resolves to an ordinary file inside the same SDK."""
    try:
        resolved = path.resolve(strict=True)
    except FileNotFoundError as error:
        raise PayloadError(f"{label} is missing") from error
    try:
        resolved.relative_to(sdk_root.resolve(strict=True))
    except ValueError as error:
        raise PayloadError(f"{label} resolves outside the SDK") from error
    ordinary(resolved, label)
    return path


def cmake_value(cache: Path, name: str) -> str:
    pattern = re.compile(rf"^{re.escape(name)}:[A-Z]+=(.*)$")
    values = [m.group(1) for line in cache.read_text(encoding="utf-8").splitlines() if (m := pattern.match(line))]
    if len(values) != 1:
        raise PayloadError(f"CMakeCache.txt does not define {name} exactly once")
    return values[0]


def wrapper_revision(repository: Path) -> str:
    result = subprocess.run(
        ["/usr/bin/python3", "-B", str(SCRIPT.with_name("native_decompiler_source_identity.py")),
         "--repository-root", str(repository), "--profile", "wrapper"],
        stdout=subprocess.PIPE, check=True, text=True,
    )
    value = result.stdout.strip()
    if HEX.fullmatch(value) is None:
        raise PayloadError("native wrapper source identity is malformed")
    return value


def materialization_manifest_digest(repository: Path, materialization: Path) -> str:
    mode = os.environ.get("MACSCOPE_NATIVE_VERIFICATION_RECEIPT_MODE", "")
    if not mode:
        return sha256(ordinary(materialization / "MATERIALIZATION.json", "SLEIGH MATERIALIZATION.json"))
    if mode != "shared-view":
        raise PayloadError("unsupported native verification receipt mode")
    result = subprocess.run(
        ["/usr/bin/python3", "-B", str(repository / "Scripts/qualification/dev_dependency_cache.py"),
         "reuse-sleigh", "--repository-root", str(repository),
         "--materialization-root", str(materialization), "--output-json"],
        stdout=subprocess.PIPE, check=True, text=True,
    )
    value = json.loads(result.stdout)
    if (not isinstance(value, dict) or set(value) != {"identity", "manifest_sha256"}
            or not isinstance(value["manifest_sha256"], str)
            or HEX.fullmatch(value["manifest_sha256"]) is None):
        raise PayloadError("SLEIGH receipt manifest identity is malformed")
    return value["manifest_sha256"]


def scan(directory: Path, extra: tuple[str, ...]) -> None:
    markers = FORBIDDEN_MARKERS + tuple(os.fsencode(value) for value in extra if value and value != "/")
    for relative in PAYLOAD_FILES:
        payload = (directory / relative).read_bytes()
        for marker in markers:
            if marker in payload:
                raise PayloadError(f"{relative} contains a local path marker; refusing to cache it")


def verify(directory: Path, repository: Path, materialization: Path) -> dict[str, str]:
    """Domain verifier: exact path-free file set bound to the current sources and SLEIGH package."""
    found = sorted(
        path.relative_to(directory).as_posix()
        for path in directory.rglob("*")
        if not path.is_dir() or path.is_symlink()
    )
    if found != sorted(PAYLOAD_FILES):
        raise PayloadError(f"native bridge payload file set is unexpected: {found}")
    for relative in PAYLOAD_FILES:
        ordinary(directory / relative, relative)
    configuration = json.loads((directory / CONFIGURATION).read_bytes())
    expected_wrapper = wrapper_revision(repository)
    manifest = materialization_manifest_digest(repository, materialization)
    expected = {
        "cmake": [list(fact) for fact in CMAKE_FACTS],
        "materialization_manifest_sha256": manifest,
        "schema_version": SCHEMA_VERSION,
        "wrapper_revision": expected_wrapper,
    }
    if configuration != expected:
        raise PayloadError("native bridge payload configuration does not match the current sources/SLEIGH package")
    identity = (directory / IDENTITY).read_text(encoding="utf-8").splitlines()
    for value in (expected_wrapper, manifest):
        if f'    "{value}";' not in identity:
            raise PayloadError("native bridge build identity does not bind the current wrapper and SLEIGH manifest")
    architectures = subprocess.run(
        ["/usr/bin/lipo", "-archs", str(directory / ARCHIVE)], stdout=subprocess.PIPE, check=True, text=True
    ).stdout.strip()
    if architectures != "arm64":
        raise PayloadError("native bridge archive is not arm64-only")
    scan(directory, (str(repository), str(materialization), os.environ.get("HOME", "")))
    return expected


def extract(build_root: Path, payload: Path, repository: Path, materialization: Path) -> None:
    cache = ordinary(build_root / "CMakeCache.txt", "CMakeCache.txt")
    for name, _, value in CMAKE_FACTS:
        if cmake_value(cache, name) != value:
            raise PayloadError(f"native bridge build was not configured with {name}={value}")
    revision = cmake_value(cache, WRAPPER_FACT)
    if revision != wrapper_revision(repository):
        raise PayloadError("native bridge build wrapper revision differs from the declared sources")
    payload.mkdir(mode=0o700)
    for relative in (ARCHIVE, IDENTITY, INSPECTION):
        destination = payload / relative
        destination.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        shutil.copyfile(ordinary(build_root / relative, relative), destination)
    configuration = {
        "cmake": [list(fact) for fact in CMAKE_FACTS],
        "materialization_manifest_sha256": materialization_manifest_digest(repository, materialization),
        "schema_version": SCHEMA_VERSION,
        "wrapper_revision": revision,
    }
    (payload / CONFIGURATION).write_bytes(
        (json.dumps(configuration, sort_keys=True, separators=(",", ":")) + "\n").encode()
    )
    scan(payload, (str(build_root), str(materialization)))
    verify(payload, repository, materialization)


def write_atomically(destination: Path, payload: bytes) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(prefix=f".{destination.name}.", dir=destination.parent)
    try:
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(payload)
        os.chmod(temporary, 0o644)
        os.replace(temporary, destination)
    except BaseException:
        Path(temporary).unlink(missing_ok=True)
        raise


def stage(view: Path, build_root: Path, repository: Path, materialization: Path, sdk_root: Path) -> None:
    configuration = verify(view, repository, materialization)
    build_root.mkdir(parents=True, exist_ok=True)
    for relative in (ARCHIVE, IDENTITY, INSPECTION):
        destination = build_root / relative
        if destination.exists() and not destination.is_symlink() and sha256(destination) == sha256(view / relative) \
                and destination.lstat().st_nlink == 1:
            continue  # unchanged: keep the mtime so Xcode does not relink
        write_atomically(destination, (view / relative).read_bytes())
    projection = [PROJECTION_MARKER]
    projection += [f"{name}:{kind}={value}" for name, kind, value in CMAKE_FACTS]
    projection.append(f"{WRAPPER_FACT}:STRING={configuration['wrapper_revision']}")
    projected = ("\n".join(projection) + "\n").encode()
    cache = build_root / "CMakeCache.txt"
    if not cache.is_file() or cache.read_bytes() != projected:
        write_atomically(cache, projected)
    zlib = sdk_root / "usr/lib/libz.tbd"
    sdk_file(zlib, sdk_root, "SDK zlib link input")
    inputs = "\n".join(
        str(path) for path in (
            build_root / ARCHIVE,
            materialization / "package/lib/libdecomp.a",
            materialization / "package/lib/libsla.a",
            zlib,
        )
    ) + "\n"
    link_inputs = build_root / LINK_INPUTS
    if not link_inputs.is_file() or link_inputs.read_text(encoding="utf-8") != inputs:
        write_atomically(link_inputs, inputs.encode())


def clear_projection(build_root: Path) -> None:
    cache = build_root / "CMakeCache.txt"
    if cache.is_file() and not cache.is_symlink():
        with cache.open("rb") as handle:
            first = handle.readline().rstrip(b"\n")
        if first == PROJECTION_MARKER.encode():
            cache.unlink()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    commands = parser.add_subparsers(dest="command", required=True)
    for name in ("extract", "verify", "stage"):
        command = commands.add_parser(name)
        command.add_argument("--repository-root", type=Path, required=True)
        command.add_argument("--materialization-root", type=Path, required=True)
        if name == "extract":
            command.add_argument("--build-root", type=Path, required=True)
            command.add_argument("--payload", type=Path, required=True)
        elif name == "verify":
            command.add_argument("--payload", type=Path, required=True)
        else:
            command.add_argument("--view", type=Path, required=True)
            command.add_argument("--build-root", type=Path, required=True)
            command.add_argument("--sdk-root", type=Path, required=True)
    clear = commands.add_parser("clear-projection")
    clear.add_argument("--build-root", type=Path, required=True)
    arguments = parser.parse_args()
    try:
        if arguments.command == "clear-projection":
            clear_projection(arguments.build_root)
            return 0
        repository = arguments.repository_root.resolve(strict=True)
        materialization = arguments.materialization_root.resolve(strict=True)
        if arguments.command == "extract":
            extract(arguments.build_root.resolve(strict=True), arguments.payload, repository, materialization)
        elif arguments.command == "verify":
            verify(arguments.payload.resolve(strict=True), repository, materialization)
        else:
            stage(arguments.view.resolve(strict=True), arguments.build_root, repository, materialization,
                  arguments.sdk_root.resolve(strict=True))
        return 0
    except (PayloadError, OSError, ValueError, subprocess.SubprocessError) as error:
        print(f"ERROR: native bridge cache payload: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
