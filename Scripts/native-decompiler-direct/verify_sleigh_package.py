#!/usr/bin/env python3
"""CLI for the DCP-03B4 native SLEIGH package contract."""

from __future__ import annotations

import argparse
import hashlib
import os
import stat
import subprocess
import sys
from pathlib import Path

from sleigh_package import (
    PackageContractError,
    SOURCE_MANIFEST_SHA256,
    analyze_package,
    canonical_json,
    discover_install_prefix,
    verify_materialization,
    write_materialization,
    write_source_materialization,
)


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        while block := stream.read(1024 * 1024):
            digest.update(block)
    return digest.hexdigest()


def _ordinary_file(path: Path, label: str) -> Path:
    if path.is_symlink():
        raise PackageContractError(f"{label} must not be a symlink")
    resolved = path.resolve(strict=True)
    metadata = resolved.stat()
    if not stat.S_ISREG(metadata.st_mode):
        raise PackageContractError(f"{label} must be an ordinary file")
    return resolved


def _dispatched_tool(invocation: Path, dispatcher: Path) -> Path:
    # A basename-dispatched wrapper (for example a PATH command shim) selects the
    # tool by its invocation name; identify the executable it dispatches to.
    for directory in os.environ.get("PATH", "").split(os.pathsep):
        candidate = Path(directory or os.curdir) / invocation.name
        try:
            resolved = candidate.resolve(strict=True)
        except OSError:
            continue
        if (
            resolved != dispatcher
            and stat.S_ISREG(resolved.stat().st_mode)
            and os.access(resolved, os.X_OK)
        ):
            return resolved
    return dispatcher


def _tool_identity(path: Path, label: str) -> dict[str, str]:
    invocation = path.absolute()
    resolved = path.resolve(strict=True)
    if not stat.S_ISREG(resolved.stat().st_mode):
        raise PackageContractError(f"{label} must resolve to an ordinary file")
    if resolved.name != invocation.name:
        resolved = _dispatched_tool(invocation, resolved)
    completed = subprocess.run(
        [str(invocation), "--version"],
        check=False,
        capture_output=True,
        text=True,
    )
    if completed.returncode != 0:
        raise PackageContractError(f"{label} version probe failed")
    lines = completed.stdout.splitlines()
    if not lines or not lines[0]:
        raise PackageContractError(f"{label} version probe returned no identity")
    return {
        "path": str(resolved),
        "sha256": _sha256(resolved),
        "version": lines[0],
    }


def parser() -> argparse.ArgumentParser:
    value = argparse.ArgumentParser()
    subparsers = value.add_subparsers(dest="command", required=True)

    discover = subparsers.add_parser("discover")
    discover.add_argument("--extraction-root", type=Path, required=True)

    analyze = subparsers.add_parser("analyze")
    analyze.add_argument("--package-root", type=Path, required=True)

    materialize = subparsers.add_parser("materialize")
    materialize.add_argument("--package-root", type=Path, required=True)
    materialize.add_argument("--artifact", type=Path, required=True)
    materialize.add_argument("--output", type=Path, required=True)

    source = subparsers.add_parser("materialize-source")
    source.add_argument("--package-root", type=Path, required=True)
    source.add_argument("--source-manifest", type=Path, required=True)
    source.add_argument("--compiler", type=Path, required=True)
    source.add_argument("--cmake", type=Path, required=True)
    source.add_argument("--ninja", type=Path, required=True)
    source.add_argument("--output", type=Path, required=True)
    source.add_argument("--sanitizer", choices=("none", "address", "undefined"), default="none")
    source.add_argument("--compile-commands", type=Path)
    source.add_argument("--sdk-root", type=Path)

    verify = subparsers.add_parser("verify")
    verify.add_argument("--materialization-root", type=Path, required=True)
    verify.add_argument("--expected-sanitizer", choices=("none", "address", "undefined"), default="none")
    verify.add_argument("--compile-commands", type=Path)
    verify.add_argument("--compiler", type=Path)
    verify.add_argument("--sdk-root", type=Path)
    return value


def main() -> int:
    arguments = parser().parse_args()
    try:
        if arguments.command == "discover":
            root = arguments.extraction_root.resolve(strict=True)
            prefix = discover_install_prefix(root)
            print(prefix.relative_to(root).as_posix() or ".")
        elif arguments.command == "analyze":
            print(canonical_json(analyze_package(arguments.package_root)))
        elif arguments.command == "materialize":
            value = write_materialization(
                arguments.package_root,
                arguments.artifact,
                arguments.output,
            )
            print(canonical_json(value))
        elif arguments.command == "materialize-source":
            source_manifest = _ordinary_file(arguments.source_manifest, "source manifest")
            if _sha256(source_manifest) != SOURCE_MANIFEST_SHA256:
                raise PackageContractError("source manifest does not match the immutable pin")
            toolchain = {
                "compiler": _tool_identity(arguments.compiler, "source compiler"),
                "cmake": _tool_identity(arguments.cmake, "source CMake"),
                "ninja": _tool_identity(arguments.ninja, "source Ninja"),
            }
            instrumentation = None
            if arguments.sanitizer != "none":
                if arguments.compile_commands is None or arguments.sdk_root is None:
                    raise PackageContractError("sanitizer source materialization requires compile commands and SDK")
                from sleigh_sanitizer_profile import inspect_sanitizer_build

                instrumentation = inspect_sanitizer_build(
                    arguments.package_root, arguments.compile_commands,
                    arguments.compiler, arguments.sdk_root, arguments.sanitizer,
                )
            elif arguments.compile_commands is not None or arguments.sdk_root is not None:
                raise PackageContractError("production materialization does not accept sanitizer build evidence")
            value = write_source_materialization(
                arguments.package_root,
                toolchain,
                arguments.output,
                sanitizer=arguments.sanitizer,
                instrumentation=instrumentation,
            )
            print(canonical_json(value))
        elif arguments.command == "verify":
            value = verify_materialization(arguments.materialization_root,
                                           expected_sanitizer=arguments.expected_sanitizer)
            evidence_arguments = (arguments.compile_commands, arguments.compiler, arguments.sdk_root)
            if any(item is not None for item in evidence_arguments):
                if any(item is None for item in evidence_arguments) or arguments.expected_sanitizer == "none":
                    raise PackageContractError("producer revalidation requires one profile, compile commands, compiler and SDK")
                from sleigh_sanitizer_profile import inspect_sanitizer_build

                instrumentation = inspect_sanitizer_build(
                    arguments.materialization_root / "package", arguments.compile_commands,
                    arguments.compiler, arguments.sdk_root, arguments.expected_sanitizer,
                )
                if instrumentation != value["sourceBuild"]["instrumentation"]:
                    raise PackageContractError("sanitizer build evidence differs from its recorded identity")
                if _tool_identity(arguments.compiler, "source compiler") != value["sourceBuild"]["toolchain"]["compiler"]:
                    raise PackageContractError("current compiler differs from the sanitizer source compiler")
            print(canonical_json(value))
        else:  # pragma: no cover - argparse enforces the command set.
            raise AssertionError(arguments.command)
    except (PackageContractError, OSError, ValueError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
