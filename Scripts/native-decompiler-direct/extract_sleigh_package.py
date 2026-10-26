#!/usr/bin/env python3
"""Safely extract one checksum-verified DCP-03B4 release archive."""

from __future__ import annotations

import argparse
import os
import pathlib
import stat
import sys
import tarfile

MAX_MEMBERS = 100_000
MAX_TOTAL_BYTES = 8 * 1024 * 1024 * 1024
MAX_FILE_BYTES = 2 * 1024 * 1024 * 1024
MAX_PATH_BYTES = 4096
COPY_CHUNK = 1024 * 1024


class ExtractionError(RuntimeError):
    pass


def _parts(name: str) -> tuple[str, ...]:
    if not name or "\x00" in name or len(name.encode("utf-8")) > MAX_PATH_BYTES:
        raise ExtractionError("archive contains an invalid member name")
    pure = pathlib.PurePosixPath(name)
    if pure.is_absolute() or any(part in {"", ".", ".."} for part in pure.parts):
        raise ExtractionError("archive member path escapes the extraction root")
    if "\\" in name or ":" in pure.parts[0]:
        raise ExtractionError("archive member path uses a non-portable form")
    return pure.parts


def _open_directory(path: pathlib.Path, label: str) -> pathlib.Path:
    try:
        metadata = path.lstat()
    except OSError as error:
        raise ExtractionError(f"{label} is missing or inaccessible: {error}") from error
    if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISDIR(metadata.st_mode):
        raise ExtractionError(f"{label} must be an ordinary directory")
    return path.resolve(strict=True)


def extract(archive: pathlib.Path, destination: pathlib.Path) -> None:
    archive = archive.resolve(strict=True)
    if stat.S_ISLNK(archive.lstat().st_mode) or not archive.is_file():
        raise ExtractionError("archive must be an ordinary file")
    root = _open_directory(destination, "extraction destination")
    if any(root.iterdir()):
        raise ExtractionError("extraction destination must be empty")

    try:
        handle = tarfile.open(archive, mode="r:gz")
    except (tarfile.TarError, OSError) as error:
        raise ExtractionError("release artifact is not a valid gzip-compressed tar archive") from error

    with handle:
        members = handle.getmembers()
        if not members or len(members) > MAX_MEMBERS:
            raise ExtractionError("archive member count exceeds the fixed bound")
        seen: set[tuple[str, ...]] = set()
        planned: list[tuple[tarfile.TarInfo, tuple[str, ...], int]] = []
        total = 0
        for member in members:
            parts = _parts(member.name.rstrip("/"))
            if parts in seen:
                raise ExtractionError("archive contains a duplicate member path")
            seen.add(parts)
            if member.isdir():
                mode = 0o755
            elif member.isfile():
                if member.size < 0 or member.size > MAX_FILE_BYTES:
                    raise ExtractionError("archive member exceeds the fixed file-size bound")
                total += member.size
                if total > MAX_TOTAL_BYTES:
                    raise ExtractionError("archive exceeds the fixed total-size bound")
                mode = 0o755 if member.mode & 0o111 else 0o644
            else:
                raise ExtractionError("archive contains a link or special file")
            planned.append((member, parts, mode))

        for member, parts, mode in planned:
            target = root.joinpath(*parts)
            try:
                target.relative_to(root)
            except ValueError as error:
                raise ExtractionError("archive member path escapes the extraction root") from error
            if member.isdir():
                target.mkdir(mode=mode, parents=True, exist_ok=True)
                if target.is_symlink():
                    raise ExtractionError("archive directory resolved through a symlink")
                continue

            target.parent.mkdir(mode=0o755, parents=True, exist_ok=True)
            current = root
            for part in parts[:-1]:
                current /= part
                metadata = current.lstat()
                if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISDIR(metadata.st_mode):
                    raise ExtractionError("archive parent is not an ordinary directory")
            source = handle.extractfile(member)
            if source is None:
                raise ExtractionError("archive file could not be opened")
            flags = (
                os.O_WRONLY
                | os.O_CREAT
                | os.O_EXCL
                | getattr(os, "O_NOFOLLOW", 0)
                | getattr(os, "O_CLOEXEC", 0)
            )
            try:
                descriptor = os.open(target, flags, mode)
            except OSError as error:
                raise ExtractionError("archive file could not be created safely") from error
            copied = 0
            try:
                with os.fdopen(descriptor, "wb") as output, source:
                    descriptor = -1
                    while True:
                        chunk = source.read(COPY_CHUNK)
                        if not chunk:
                            break
                        copied += len(chunk)
                        if copied > member.size:
                            raise ExtractionError("archive member expanded beyond its declared size")
                        output.write(chunk)
                    output.flush()
                    os.fsync(output.fileno())
            finally:
                if descriptor >= 0:
                    os.close(descriptor)
            if copied != member.size:
                raise ExtractionError("archive member size differs from its declaration")
            os.chmod(target, mode, follow_symlinks=False)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--archive", type=pathlib.Path, required=True)
    parser.add_argument("--destination", type=pathlib.Path, required=True)
    arguments = parser.parse_args()
    try:
        extract(arguments.archive, arguments.destination)
    except (ExtractionError, OSError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
