#!/usr/bin/env python3
"""Create one immutable local corpus manifest for both baseline and candidate runs."""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import plistlib


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def executable(path):
    path = path.expanduser().resolve(strict=True)
    if path.is_dir() and path.suffix == ".app":
        with (path / "Contents/Info.plist").open("rb") as stream:
            name = plistlib.load(stream)["CFBundleExecutable"]
        if not isinstance(name, str) or Path(name).name != name:
            raise ValueError("Invalid bundle executable name")
        path = (path / "Contents/MacOS" / name).resolve(strict=True)
    if not path.is_file():
        raise ValueError("Corpus input must be an ordinary executable file or .app bundle")
    return path


def build_manifest(paths, modes, warmups, iterations, slice_index):
    if not 1 <= warmups <= 5 or not 20 <= iterations <= 200:
        raise ValueError("Use 1...5 warmups and 20...200 measured iterations")
    if not 1 <= len(paths) * len(modes) <= 20:
        raise ValueError("The combined file/mode count must be 1...20")
    if slice_index is not None and slice_index < 0:
        raise ValueError("Slice index cannot be negative")
    inputs = []
    for index, original in enumerate(paths):
        path = executable(original)
        digest = sha256(path)
        for mode in modes:
            if mode not in ("inProcess", "xpc"):
                raise ValueError("Invalid mode")
            inputs.append({"id": "input-{:02d}-{}".format(index + 1, mode),
                           "path": str(path), "sha256": digest,
                           "sizeBytes": path.stat().st_size, "mode": mode,
                           "requestedSliceIndex": slice_index})
    return {"schemaVersion": 1, "warmupIterations": warmups,
            "measuredIterations": iterations, "inputs": inputs}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", type=Path, action="append", required=True)
    parser.add_argument("--mode", choices=("inProcess", "xpc"), action="append")
    parser.add_argument("--warmups", type=int, default=2)
    parser.add_argument("--iterations", type=int, default=20)
    parser.add_argument("--slice-index", type=int)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    value = build_manifest(args.input, args.mode or ["inProcess", "xpc"],
                           args.warmups, args.iterations, args.slice_index)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("x", encoding="utf-8") as stream:
        json.dump(value, stream, sort_keys=True, indent=2)
        stream.write("\n")
    print(args.output.resolve())


if __name__ == "__main__":
    main()
