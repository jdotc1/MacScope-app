#!/usr/bin/env python3
"""Verify the compiled MachOKit identity in AnalysisWorkerXPCService.

The direct-source dependency verifier proves the source tree supplied to the
build.  This verifier closes the other side of that contract: the built worker
must carry exactly one canonical marker binding it to the reviewed MachOKit
revision and governed source identity.  The separately computed final
materialization digest is not a compiled-source identity.  This verifier
intentionally scans the worker
as bounded opaque bytes; it does not depend on Mach-O tooling or trust symbol
names that may be stripped from a Release product.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import stat
import sys
from pathlib import Path


MACHOKIT_REVISION = "773e10797abc53914b94c2ee8c6f40f5da0b06eb"
GOVERNED_SOURCE_IDENTITY = (
    "b2f928cfc635b3a539129d1dbd50464c9d218c4a815553bc4b710ac813a790ea"
)
BUILD_IDENTITY_PREFIX = "MACSCOPE_MACHOKIT_BUILD_ID"
MARKER_PREFIX = BUILD_IDENTITY_PREFIX.encode("ascii") + b":"
EXPECTED_MARKER = (
    MARKER_PREFIX
    + MACHOKIT_REVISION.encode("ascii")
    + b":"
    + GOVERNED_SOURCE_IDENTITY.encode("ascii")
)
MARKER_PATTERN = re.compile(
    re.escape(MARKER_PREFIX)
    + rb"([0-9a-f]{40}):([0-9a-f]{64})"
)

# A worker executable is currently far below this limit.  The generous fixed
# ceiling admits normal linker growth while ensuring a corrupt or adversarial
# path cannot make the verifier consume unbounded memory.
MAX_EXECUTABLE_BYTES = 512 * 1024 * 1024
READ_CHUNK_BYTES = 1024 * 1024


class MachOKitCompiledIdentityError(RuntimeError):
    """The built worker cannot prove the reviewed MachOKit source identity."""


def _stable_identity(metadata: os.stat_result) -> tuple[int, int, int, int, int, int, int]:
    return (
        metadata.st_dev,
        metadata.st_ino,
        metadata.st_mode,
        metadata.st_nlink,
        metadata.st_size,
        metadata.st_mtime_ns,
        metadata.st_ctime_ns,
    )


def _read_bounded_ordinary_file(path: Path) -> bytes:
    """Read one stable, singly linked regular file without following symlinks."""

    try:
        before = path.lstat()
    except OSError as error:
        raise MachOKitCompiledIdentityError(
            f"AnalysisWorker executable is unavailable: {error}"
        ) from error
    if stat.S_ISLNK(before.st_mode):
        raise MachOKitCompiledIdentityError(
            "AnalysisWorker executable must not be a symbolic link"
        )
    if not stat.S_ISREG(before.st_mode):
        raise MachOKitCompiledIdentityError(
            "AnalysisWorker executable must be a regular file"
        )
    if before.st_nlink != 1:
        raise MachOKitCompiledIdentityError(
            "AnalysisWorker executable must not be multiply linked"
        )
    if before.st_size <= 0 or before.st_size > MAX_EXECUTABLE_BYTES:
        raise MachOKitCompiledIdentityError(
            "AnalysisWorker executable violates the size bound"
        )

    flags = os.O_RDONLY
    if hasattr(os, "O_CLOEXEC"):
        flags |= os.O_CLOEXEC
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        descriptor = os.open(path, flags)
    except OSError as error:
        raise MachOKitCompiledIdentityError(
            f"AnalysisWorker executable cannot be opened safely: {error}"
        ) from error
    try:
        opened = os.fstat(descriptor)
        if _stable_identity(opened) != _stable_identity(before):
            raise MachOKitCompiledIdentityError(
                "AnalysisWorker executable changed before inspection"
            )
        if not stat.S_ISREG(opened.st_mode) or opened.st_nlink != 1:
            raise MachOKitCompiledIdentityError(
                "AnalysisWorker executable changed into an unsafe file"
            )

        chunks: list[bytes] = []
        remaining = opened.st_size
        while remaining:
            chunk = os.read(descriptor, min(READ_CHUNK_BYTES, remaining))
            if not chunk:
                raise MachOKitCompiledIdentityError(
                    "AnalysisWorker executable was truncated during inspection"
                )
            chunks.append(chunk)
            remaining -= len(chunk)
        if os.read(descriptor, 1):
            raise MachOKitCompiledIdentityError(
                "AnalysisWorker executable grew during inspection"
            )
        after = os.fstat(descriptor)
        if _stable_identity(after) != _stable_identity(opened):
            raise MachOKitCompiledIdentityError(
                "AnalysisWorker executable changed during inspection"
            )
        return b"".join(chunks)
    finally:
        os.close(descriptor)


def verify_analysis_worker_executable(path: Path) -> dict[str, str]:
    """Return the exact reviewed compiled identity or raise fail closed."""

    return verify_analysis_worker_payload(_read_bounded_ordinary_file(path))


def verify_analysis_worker_payload(payload: bytes) -> dict[str, str]:
    """Parse the same stable fresh-worker bytes that the caller binds once."""
    prefix_count = payload.count(MARKER_PREFIX)
    if prefix_count == 0:
        raise MachOKitCompiledIdentityError(
            "AnalysisWorker executable is missing the MachOKit identity marker"
        )
    if prefix_count != 1:
        raise MachOKitCompiledIdentityError(
            "AnalysisWorker executable contains duplicate MachOKit identity markers"
        )

    matches = list(MARKER_PATTERN.finditer(payload))
    if len(matches) != 1:
        raise MachOKitCompiledIdentityError(
            "AnalysisWorker executable contains a malformed MachOKit identity marker"
        )
    match = matches[0]
    if match.group(0) != EXPECTED_MARKER:
        revision = match.group(1).decode("ascii")
        source_identity = match.group(2).decode("ascii")
        if revision != MACHOKIT_REVISION:
            raise MachOKitCompiledIdentityError(
                "AnalysisWorker MachOKit revision does not match the reviewed contract"
            )
        if source_identity != GOVERNED_SOURCE_IDENTITY:
            raise MachOKitCompiledIdentityError(
                "AnalysisWorker MachOKit governed source identity does not match the reviewed contract"
            )
        raise MachOKitCompiledIdentityError(
            "AnalysisWorker MachOKit marker does not use the canonical syntax"
        )

    return {
        "schema": "macscope-machokit-compiled-identity-v1",
        "revision": MACHOKIT_REVISION,
        "governed_source_identity": GOVERNED_SOURCE_IDENTITY,
    }


def parse_arguments(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Verify the compiled MachOKit identity in AnalysisWorkerXPCService."
    )
    parser.add_argument("--executable", type=Path, required=True)
    parser.add_argument(
        "--json",
        action="store_true",
        help="emit the verified identity as canonical JSON for provenance tooling",
    )
    parser.add_argument("--quiet", action="store_true")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    arguments = parse_arguments(argv)
    try:
        identity = verify_analysis_worker_executable(arguments.executable)
    except (MachOKitCompiledIdentityError, OSError) as error:
        print(f"MachOKit compiled-identity verification failed: {error}", file=sys.stderr)
        return 1
    if arguments.json:
        print(json.dumps(identity, sort_keys=True, separators=(",", ":")))
    elif not arguments.quiet:
        print(
            "verified AnalysisWorker MachOKit compiled identity: "
            f"{identity['revision']} / {identity['governed_source_identity']}"
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
