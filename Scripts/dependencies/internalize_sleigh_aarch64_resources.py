#!/usr/bin/env python3
"""Internalize the pinned AArch64 SLEIGH resources into an external work root.

This is deliberately offline.  The committed resource closure is copied from
ThirdParty/SleighNative/AARCH64; generated output (including its manifest) is
kept outside the repository so it cannot become an accidental source input.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import stat
import tempfile
from pathlib import Path

COMPONENT_ID = "sleigh-aarch64-processor-resources"
SLEIGH_VERSION = "12.1.2"
SLEIGH_GIT_REVISION = "bfd38a983b4aa53dd386365e1df5ed5499b7e2fb"
GHIDRA_VERSION = "12.1.2"
GHIDRA_GIT_REVISION = "c0f584bf229fffba61b36431f3ce30c0c3e4e682"
ARCHIVE_SHA256 = "e1391c811de7b2d79c9e8a1f6f74cd9ade23baf55deebd75c626a3152e5e451a"
RESOURCE_RELATIVE_ROOT = Path("package/share/sleigh/specfiles/Ghidra/Processors/AARCH64/data/languages")
CRITICAL_NAMES = (
    "AppleSilicon.ldefs",
    "AARCH64_AppleSilicon.sla",
    "AARCH64.pspec",
    "AARCH64_apple.cspec",
)


class MaterializationError(RuntimeError):
    pass


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        while chunk := stream.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def _ordinary_file(path: Path) -> None:
    metadata = path.lstat()
    if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISREG(metadata.st_mode):
        raise MaterializationError(f"resource is not an ordinary file: {path}")


def _tree_digest(files: list[tuple[str, int, str]]) -> str:
    digest = hashlib.sha256()
    for relative, size, sha256 in files:
        digest.update(relative.encode("utf-8"))
        digest.update(b"\0")
        digest.update(str(size).encode("ascii"))
        digest.update(b"\0")
        digest.update(sha256.encode("ascii"))
        digest.update(b"\0")
    return digest.hexdigest()


def inspect(source_root: Path) -> dict[str, object]:
    source_root = source_root.resolve(strict=True)
    if not source_root.is_dir():
        raise MaterializationError("source closure must be a directory")
    paths = sorted(source_root.iterdir(), key=lambda path: os.fsencode(path.name))
    if len(paths) != 29:
        raise MaterializationError(f"expected 29 AArch64 resources, found {len(paths)}")
    files: list[tuple[str, int, str]] = []
    for path in paths:
        _ordinary_file(path)
        files.append((path.name, path.stat().st_size, _sha256(path)))
    names = {name for name, _, _ in files}
    missing = sorted(set(CRITICAL_NAMES) - names)
    if missing:
        raise MaterializationError(f"missing Apple Silicon resource(s): {', '.join(missing)}")
    return {
        "relativeRoot": RESOURCE_RELATIVE_ROOT.as_posix(),
        "fileCount": len(files),
        "totalBytes": sum(size for _, size, _ in files),
        "treeSha256": _tree_digest(files),
        "criticalFileSha256": {name: sha256 for name, _, sha256 in files if name in CRITICAL_NAMES},
        "files": [{"name": name, "size": size, "sha256": sha256} for name, size, sha256 in files],
    }


def materialize(source_root: Path, destination: Path, repository_root: Path) -> dict[str, object]:
    destination = destination.absolute()
    repository_root = repository_root.resolve(strict=True)
    if destination == repository_root or repository_root in destination.parents:
        raise MaterializationError("destination must be an external Derived Data/work root")
    if destination.exists() or destination.is_symlink():
        raise MaterializationError(f"destination already exists: {destination}")
    analysis = inspect(source_root)
    destination.parent.mkdir(parents=True, exist_ok=True)
    staging = Path(tempfile.mkdtemp(prefix=f".{destination.name}.", dir=destination.parent))
    try:
        output_root = staging / "package" / RESOURCE_RELATIVE_ROOT.relative_to("package")
        output_root.mkdir(parents=True)
        for entry in analysis["files"]:
            name = str(entry["name"])
            shutil.copyfile(Path(source_root) / name, output_root / name)
            if _sha256(output_root / name) != entry["sha256"]:
                raise MaterializationError(f"copied resource digest changed: {name}")
        manifest = {
            "schemaVersion": 1,
            "componentId": COMPONENT_ID,
            "sleighVersion": SLEIGH_VERSION,
            "sleighGitRevision": SLEIGH_GIT_REVISION,
            "ghidraVersion": GHIDRA_VERSION,
            "ghidraGitRevision": GHIDRA_GIT_REVISION,
            "upstreamArtifactSha256": ARCHIVE_SHA256,
            "source": "ThirdParty/SleighNative/AARCH64",
            "package": analysis,
        }
        (staging / "MATERIALIZATION.json").write_text(
            json.dumps(manifest, sort_keys=True, separators=(",", ":")) + "\n", encoding="utf-8"
        )
        staging.rename(destination)
        return manifest
    except Exception:
        shutil.rmtree(staging, ignore_errors=True)
        raise


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--destination", type=Path, required=True)
    parser.add_argument("--repository-root", type=Path, default=Path(__file__).resolve().parents[2])
    args = parser.parse_args()
    try:
        source = args.repository_root / "ThirdParty/SleighNative/AARCH64"
        manifest = materialize(source, args.destination, args.repository_root)
    except (MaterializationError, OSError, ValueError) as error:
        print(f"ERROR: {error}")
        return 1
    print(json.dumps(manifest, sort_keys=True, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
