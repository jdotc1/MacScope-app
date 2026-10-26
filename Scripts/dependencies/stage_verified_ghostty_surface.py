#!/usr/bin/env python3
"""Stage the exact manifest-bound Ghostty surface leaves consumed by Xcode."""

from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import stat
import tempfile


SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
CHUNK_SIZE = 1024 * 1024
STAGED_DESCRIPTOR = "STAGED_GHOSTTY_SURFACE.json"
LEAVES = (
    (
        "archive",
        Path("macos-arm64/libghostty-internal.a"),
        Path("libghostty-internal.a"),
        "archive_sha256",
    ),
    (
        "header",
        Path("macos-arm64/Headers/ghostty.h"),
        Path("Headers/ghostty.h"),
        "header_sha256",
    ),
    (
        "module_map",
        Path("macos-arm64/Headers/module.modulemap"),
        Path("Headers/module.modulemap"),
        "module_map_sha256",
    ),
)


class GhosttySurfaceStageError(RuntimeError):
    pass


def _ordinary_file(path: Path, *, label: str) -> os.stat_result:
    try:
        metadata = path.lstat()
    except OSError as error:
        raise GhosttySurfaceStageError(f"cannot inspect {label}: {error}") from error
    if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISREG(metadata.st_mode):
        raise GhosttySurfaceStageError(f"{label} is not one ordinary file")
    return metadata


def _stable_bytes(path: Path, *, label: str, maximum_size: int | None = None) -> bytes:
    before = _ordinary_file(path, label=label)
    if maximum_size is not None and before.st_size > maximum_size:
        raise GhosttySurfaceStageError(f"{label} exceeds its size limit")
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(path, flags)
    except OSError as error:
        raise GhosttySurfaceStageError(f"cannot open {label}: {error}") from error
    try:
        opened = os.fstat(descriptor)
        if (
            not stat.S_ISREG(opened.st_mode)
            or (opened.st_dev, opened.st_ino) != (before.st_dev, before.st_ino)
        ):
            raise GhosttySurfaceStageError(f"{label} changed during admission")
        chunks: list[bytes] = []
        total = 0
        while True:
            chunk = os.read(descriptor, CHUNK_SIZE)
            if not chunk:
                break
            total += len(chunk)
            if maximum_size is not None and total > maximum_size:
                raise GhosttySurfaceStageError(f"{label} exceeds its size limit")
            chunks.append(chunk)
        after = os.fstat(descriptor)
    finally:
        os.close(descriptor)
    final = _ordinary_file(path, label=label)
    stable_fields = ("st_dev", "st_ino", "st_mode", "st_size", "st_mtime_ns", "st_ctime_ns")
    if any(getattr(before, field) != getattr(after, field) for field in stable_fields) or any(
        getattr(after, field) != getattr(final, field) for field in stable_fields
    ):
        raise GhosttySurfaceStageError(f"{label} changed while it was read")
    return b"".join(chunks)


def _parse_manifest(path: Path) -> tuple[dict[str, str], str]:
    payload = _stable_bytes(path, label="Ghostty surface manifest", maximum_size=64 * 1024)
    try:
        text = payload.decode("utf-8")
    except UnicodeDecodeError as error:
        raise GhosttySurfaceStageError("Ghostty surface manifest is not UTF-8") from error
    values: dict[str, str] = {}
    for line in text.splitlines():
        if not line or "=" not in line:
            raise GhosttySurfaceStageError("Ghostty surface manifest is malformed")
        key, value = line.split("=", 1)
        if not key or not value or key in values:
            raise GhosttySurfaceStageError("Ghostty surface manifest has an invalid field")
        values[key] = value
    fixed = {
        "schema": "3",
        "external_io_abi_version": "1",
        "networking": "disabled",
        "architecture": "arm64",
        "library_identifier": "macos-arm64",
    }
    for key, expected in fixed.items():
        if values.get(key) != expected:
            raise GhosttySurfaceStageError(
                f"Ghostty surface manifest has unexpected {key}"
            )
    for _, _, _, digest_key in LEAVES:
        if SHA256_RE.fullmatch(values.get(digest_key, "")) is None:
            raise GhosttySurfaceStageError(
                f"Ghostty surface manifest lacks exact {digest_key}"
            )
    return values, hashlib.sha256(payload).hexdigest()


def _reject_symlink_components(root: Path, relative: Path, *, label: str) -> Path:
    current = root
    if current.is_symlink() or not current.is_dir():
        raise GhosttySurfaceStageError(f"{label} root is not an ordinary directory")
    for component in relative.parts:
        current = current / component
        if current.is_symlink():
            raise GhosttySurfaceStageError(f"{label} traverses a symbolic link")
    return current


def _copy_verified(source: Path, destination: Path, *, expected_sha256: str, label: str) -> None:
    before = _ordinary_file(source, label=label)
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        source_descriptor = os.open(source, flags)
    except OSError as error:
        raise GhosttySurfaceStageError(f"cannot open {label}: {error}") from error
    destination.parent.mkdir(parents=True, exist_ok=True)
    output_flags = (
        os.O_WRONLY
        | os.O_CREAT
        | os.O_EXCL
        | getattr(os, "O_CLOEXEC", 0)
        | getattr(os, "O_NOFOLLOW", 0)
    )
    try:
        destination_descriptor = os.open(destination, output_flags, 0o444)
    except OSError as error:
        os.close(source_descriptor)
        raise GhosttySurfaceStageError(f"cannot create staged {label}: {error}") from error
    digest = hashlib.sha256()
    try:
        opened = os.fstat(source_descriptor)
        if (
            not stat.S_ISREG(opened.st_mode)
            or (opened.st_dev, opened.st_ino) != (before.st_dev, before.st_ino)
        ):
            raise GhosttySurfaceStageError(f"{label} changed during admission")
        while True:
            chunk = os.read(source_descriptor, CHUNK_SIZE)
            if not chunk:
                break
            digest.update(chunk)
            view = memoryview(chunk)
            while view:
                written = os.write(destination_descriptor, view)
                if written <= 0:
                    raise GhosttySurfaceStageError(f"could not write staged {label}")
                view = view[written:]
        os.fsync(destination_descriptor)
        after = os.fstat(source_descriptor)
    finally:
        os.close(destination_descriptor)
        os.close(source_descriptor)
    final = _ordinary_file(source, label=label)
    stable_fields = ("st_dev", "st_ino", "st_mode", "st_size", "st_mtime_ns", "st_ctime_ns")
    if any(getattr(before, field) != getattr(after, field) for field in stable_fields) or any(
        getattr(after, field) != getattr(final, field) for field in stable_fields
    ):
        raise GhosttySurfaceStageError(f"{label} changed while it was staged")
    if digest.hexdigest() != expected_sha256:
        raise GhosttySurfaceStageError(f"{label} does not match the verified manifest")


def _canonical_path(path: Path, *, label: str, must_exist: bool) -> Path:
    if not path.is_absolute():
        raise GhosttySurfaceStageError(f"{label} must be absolute")
    if path.is_symlink():
        raise GhosttySurfaceStageError(f"{label} must not be a symbolic link")
    try:
        if must_exist:
            return path.resolve(strict=True)
        parent = path.parent.resolve(strict=True)
        return parent / path.name
    except OSError as error:
        raise GhosttySurfaceStageError(f"cannot resolve {label}: {error}") from error


def stage_surface(
    manifest: Path,
    artifact_root: Path,
    destination: Path,
    allowed_root: Path,
) -> dict[str, object]:
    manifest = _canonical_path(manifest, label="manifest", must_exist=True)
    artifact_root = _canonical_path(artifact_root, label="artifact root", must_exist=True)
    allowed_root = _canonical_path(allowed_root, label="allowed root", must_exist=True)
    destination = _canonical_path(destination, label="destination", must_exist=False)
    if destination == allowed_root or allowed_root not in destination.parents:
        raise GhosttySurfaceStageError("destination is outside the build-owned staging root")
    if destination.parent != allowed_root:
        raise GhosttySurfaceStageError("destination must be a direct child of the staging root")
    if allowed_root.is_symlink() or not allowed_root.is_dir():
        raise GhosttySurfaceStageError("allowed root is not an ordinary directory")

    values, manifest_sha256 = _parse_manifest(manifest)
    staged_leaves: list[dict[str, str]] = []
    lock_path = allowed_root / f".{destination.name}.stage.lock"
    lock_descriptor = os.open(
        lock_path,
        os.O_RDWR | os.O_CREAT | getattr(os, "O_CLOEXEC", 0),
        0o600,
    )
    staging: Path | None = None
    backup: Path | None = None
    try:
        fcntl.flock(lock_descriptor, fcntl.LOCK_EX)
        staging = Path(tempfile.mkdtemp(prefix=f".{destination.name}.stage.", dir=allowed_root))
        for role, source_relative, destination_relative, digest_key in LEAVES:
            source = _reject_symlink_components(
                artifact_root, source_relative, label=f"Ghostty surface {role}"
            )
            target = staging / destination_relative
            expected = values[digest_key]
            _copy_verified(source, target, expected_sha256=expected, label=f"Ghostty surface {role}")
            staged_leaves.append(
                {
                    "role": role,
                    "relative_path": destination_relative.as_posix(),
                    "sha256": expected,
                }
            )
        descriptor: dict[str, object] = {
            "leaves": staged_leaves,
            "schema_version": 1,
            "source_manifest_sha256": manifest_sha256,
        }
        descriptor_bytes = (
            json.dumps(descriptor, sort_keys=True, separators=(",", ":")) + "\n"
        ).encode("utf-8")
        descriptor_path = staging / STAGED_DESCRIPTOR
        descriptor_path.write_bytes(descriptor_bytes)
        descriptor_path.chmod(0o444)

        if destination.exists() or destination.is_symlink():
            if destination.is_symlink() or not destination.is_dir():
                raise GhosttySurfaceStageError("existing staged destination is unsafe")
            backup = allowed_root / f".{destination.name}.previous.{os.getpid()}"
            if backup.exists() or backup.is_symlink():
                raise GhosttySurfaceStageError("staged replacement backup already exists")
            os.replace(destination, backup)
        try:
            os.replace(staging, destination)
            staging = None
        except BaseException:
            if backup is not None and not destination.exists():
                os.replace(backup, destination)
                backup = None
            raise
        if backup is not None:
            shutil.rmtree(backup)
            backup = None
        return descriptor
    finally:
        if staging is not None and staging.exists():
            shutil.rmtree(staging)
        if backup is not None and backup.exists() and not destination.exists():
            os.replace(backup, destination)
        fcntl.flock(lock_descriptor, fcntl.LOCK_UN)
        os.close(lock_descriptor)


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--artifact-root", type=Path, required=True)
    parser.add_argument("--destination", type=Path, required=True)
    parser.add_argument("--allowed-root", type=Path, required=True)
    return parser.parse_args()


def main() -> int:
    arguments = parse_arguments()
    try:
        descriptor = stage_surface(
            arguments.manifest,
            arguments.artifact_root,
            arguments.destination,
            arguments.allowed_root,
        )
    except GhosttySurfaceStageError as error:
        raise SystemExit(f"ERROR: {error}") from error
    print(json.dumps(descriptor, sort_keys=True, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
