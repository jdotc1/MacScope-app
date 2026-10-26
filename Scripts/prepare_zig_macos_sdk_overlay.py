#!/usr/bin/env python3
"""Prepare a closed macOS SDK view for pinned Zig on arm64e-only Xcode SDKs."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import sys


SCHEMA_VERSION = 1
RECORD_NAME = "MACSCOPE_ZIG_SDK_OVERLAY.json"


class OverlayError(RuntimeError):
    pass


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def sdk_targets(text: str) -> set[str]:
    return set(re.findall(r"(?<![A-Za-z0-9_])(?:arm64e|arm64)-macos(?![A-Za-z0-9_])", text))


def primary_sdk_targets(text: str) -> set[str]:
    match = re.search(r"^targets:\s*\[([^]]*)\]", text, flags=re.MULTILINE)
    if match is None:
        raise OverlayError("macOS SDK libSystem stub has no primary target list")
    return sdk_targets(match.group(1))


def compatibility_text(source: str) -> str:
    result = re.sub(
        r"(?<![A-Za-z0-9_])arm64e-macos(?![A-Za-z0-9_])",
        "arm64-macos, arm64e-macos",
        source,
    )
    return re.sub(
        r"(?<![A-Za-z0-9_])arm64e-maccatalyst(?![A-Za-z0-9_])",
        "arm64-maccatalyst, arm64e-maccatalyst",
        result,
    )


def expected_links(source: Path) -> dict[Path, Path]:
    links: dict[Path, Path] = {}
    for item in source.iterdir():
        if item.name != "usr":
            links[Path(item.name)] = item
    for item in (source / "usr").iterdir():
        if item.name != "lib":
            links[Path("usr") / item.name] = item
    for item in (source / "usr/lib").iterdir():
        if item.name not in {"libSystem.B.tbd", "libSystem.tbd"}:
            links[Path("usr/lib") / item.name] = item
    return links


def make_record(
    source: Path, generated: Path, xcrun: Path, shim: Path
) -> dict[str, object]:
    return {
        "generated_libsystem_sha256": sha256(generated),
        "schema_version": SCHEMA_VERSION,
        "sdk_root": str(source),
        "source_libsystem_sha256": sha256(source / "usr/lib/libSystem.B.tbd"),
        "xcrun": str(xcrun),
        "xcrun_shim_sha256": sha256(shim),
    }


def verify_overlay(output: Path, source: Path, xcrun: Path) -> dict[str, object]:
    if not output.is_dir() or output.is_symlink():
        raise OverlayError("existing SDK compatibility overlay failed verification")
    effective = output / "sdk"
    record_path = output / RECORD_NAME
    generated = effective / "usr/lib/libSystem.B.tbd"
    shim = output / "xcrun-shim/xcrun"
    if not record_path.is_file() or not generated.is_file() or not shim.is_file():
        raise OverlayError("existing SDK compatibility overlay failed verification")
    try:
        record = json.loads(record_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise OverlayError("existing SDK compatibility overlay failed verification") from error
    if record != make_record(source, generated, xcrun, shim):
        raise OverlayError("existing SDK compatibility overlay failed verification")
    if primary_sdk_targets(generated.read_text(encoding="utf-8")) != {
        "arm64-macos",
        "arm64e-macos",
    }:
        raise OverlayError("existing SDK compatibility overlay failed verification")
    system_link = effective / "usr/lib/libSystem.tbd"
    if not system_link.is_symlink() or os.readlink(system_link) != "libSystem.B.tbd":
        raise OverlayError("existing SDK compatibility overlay failed verification")
    for relative, target in expected_links(source).items():
        link = effective / relative
        if not link.is_symlink() or Path(os.readlink(link)) != target:
            raise OverlayError("existing SDK compatibility overlay failed verification")
    expected_nodes = {
        Path("usr"),
        Path("usr/lib"),
        Path("usr/lib/libSystem.B.tbd"),
        Path("usr/lib/libSystem.tbd"),
    }
    for relative in expected_links(source):
        expected_nodes.add(relative)
        expected_nodes.update(parent for parent in relative.parents if parent != Path("."))
    actual_nodes = {path.relative_to(effective) for path in effective.rglob("*")}
    if actual_nodes != expected_nodes:
        raise OverlayError("existing SDK compatibility overlay failed verification")
    if {path.name for path in output.iterdir()} != {"sdk", "xcrun-shim", RECORD_NAME}:
        raise OverlayError("existing SDK compatibility overlay failed verification")
    if {path.name for path in (output / "xcrun-shim").iterdir()} != {"xcrun"}:
        raise OverlayError("existing SDK compatibility overlay failed verification")
    return {
        "compatibility_applied": True,
        "effective_sdk_root": str(effective),
        "sdk_root": str(source),
        "source_libsystem_sha256": record["source_libsystem_sha256"],
        "xcrun_shim_dir": str(output / "xcrun-shim"),
    }


def create_overlay(output: Path, source: Path, xcrun: Path) -> dict[str, object]:
    if output.exists() or output.is_symlink():
        return verify_overlay(output, source, xcrun)
    output.parent.mkdir(parents=True, exist_ok=True)
    staging = output.parent / f".{output.name}.staging.{os.getpid()}"
    if staging.exists() or staging.is_symlink():
        raise OverlayError(f"staging path already exists: {staging}")
    try:
        effective = staging / "sdk"
        (effective / "usr/lib").mkdir(parents=True)
        for relative, target in expected_links(source).items():
            link = effective / relative
            link.parent.mkdir(parents=True, exist_ok=True)
            link.symlink_to(target)

        source_libsystem = source / "usr/lib/libSystem.B.tbd"
        generated = effective / "usr/lib/libSystem.B.tbd"
        generated.write_text(
            compatibility_text(source_libsystem.read_text(encoding="utf-8")),
            encoding="utf-8",
        )
        generated.chmod(0o444)
        (effective / "usr/lib/libSystem.tbd").symlink_to("libSystem.B.tbd")

        shim_dir = staging / "xcrun-shim"
        shim_dir.mkdir()
        shim = shim_dir / "xcrun"
        shim.write_text(
            "#!/bin/bash\n"
            "set -euo pipefail\n"
            "if [[ \"$*\" == \"--sdk macosx --show-sdk-path\" ]]; then\n"
            f"  printf '%s\\n' '{output / 'sdk'}'\n"
            "  exit 0\n"
            "fi\n"
            f"exec '{xcrun}' \"$@\"\n",
            encoding="utf-8",
        )
        shim.chmod(0o555)
        record = make_record(source, generated, xcrun, shim)
        record_path = staging / RECORD_NAME
        record_path.write_text(
            json.dumps(record, sort_keys=True, separators=(",", ":")) + "\n",
            encoding="utf-8",
        )
        record_path.chmod(0o444)
        staging.rename(output)
    except Exception:
        if staging.exists() and not staging.is_symlink():
            shutil.rmtree(staging)
        raise
    return verify_overlay(output, source, xcrun)


def prepare(sdk_root: Path, output_root: Path, xcrun: Path) -> dict[str, object]:
    source = sdk_root.resolve(strict=True)
    xcrun = xcrun.resolve(strict=True)
    libsystem = source / "usr/lib/libSystem.B.tbd"
    if not libsystem.is_file():
        raise OverlayError(f"macOS SDK libSystem stub is missing: {libsystem}")
    targets = primary_sdk_targets(libsystem.read_text(encoding="utf-8"))
    source_digest = sha256(libsystem)
    if "arm64-macos" in targets:
        return {
            "compatibility_applied": False,
            "effective_sdk_root": str(source),
            "sdk_root": str(source),
            "source_libsystem_sha256": source_digest,
            "xcrun_shim_dir": None,
        }
    if "arm64e-macos" not in targets:
        raise OverlayError("macOS SDK libSystem exports neither arm64 nor arm64e")
    return create_overlay(output_root.absolute(), source, xcrun)


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)
    command = subparsers.add_parser("prepare")
    command.add_argument("--sdk-root", type=Path, required=True)
    command.add_argument("--output-root", type=Path, required=True)
    command.add_argument("--xcrun", type=Path, default=Path("/usr/bin/xcrun"))
    return parser.parse_args()


def main() -> int:
    arguments = parse_arguments()
    try:
        record = prepare(arguments.sdk_root, arguments.output_root, arguments.xcrun)
    except (OSError, OverlayError, UnicodeError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    print(json.dumps(record, sort_keys=True, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
