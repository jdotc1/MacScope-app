#!/usr/bin/env python3
"""Build the CP1 test frontend using recorded dependency and Git identities."""
from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

SOURCE = "ThirdParty/SleighNative/tests/cp1/tooling/sleigh_lift.cpp"
MATERIALIZATION = "ThirdParty/SleighNative/MATERIALIZATION.json"
BUILD_INPUTS = (SOURCE, MATERIALIZATION,
                "Scripts/dependencies/build_cp1_sleigh_lift.sh",
                "Scripts/dependencies/cp1_frontend_cache.py")
FLAGS = ("-std=c++17", "-O2", "-DNDEBUG")


def output(arguments: list[str], *, cwd: Path | None = None) -> str:
    return subprocess.check_output(arguments, cwd=cwd, text=True).strip()


def committed_inputs(root: Path) -> dict[str, str]:
    # Git object IDs are the source authority; do not rehash source/dependencies.
    subprocess.run(["/usr/bin/git", "diff", "--quiet", "HEAD", "--", *BUILD_INPUTS],
                   cwd=root, check=True)
    identities = {}
    for relative in BUILD_INPUTS:
        value = output(["/usr/bin/git", "rev-parse", f"HEAD:{relative}"], cwd=root)
        if not re.fullmatch(r"[0-9a-f]{40}", value):
            raise ValueError(f"missing committed CP1 build input: {relative}")
        identities[relative] = value
    return identities


def dependency_identity(root: Path) -> dict:
    receipt = json.loads((root / MATERIALIZATION).read_text())
    # The release receipt identifies the already-admitted library. Its original
    # compiler need not be rediscovered; the frontend toolchain is bound below.
    try:
        identity = {
            "schema_version": receipt["schemaVersion"],
            "component": receipt["componentId"],
            "sleigh_revision": receipt["sleighGitRevision"],
            "ghidra_revision": receipt["ghidraGitRevision"],
            "artifact_sha256": receipt["artifact"]["sha256"],
            "package_sha256": receipt["package"]["treeSha256"],
            "library_sha256": receipt["package"]["criticalFileSha256"]["lib/libsla.a"],
        }
    except (KeyError, TypeError) as error:
        raise ValueError("dependency receipt lacks recorded CP1 identities") from error
    if identity["schema_version"] != 1 or not identity["component"]:
        raise ValueError("unsupported CP1 dependency receipt")
    for field in ("artifact_sha256", "package_sha256", "library_sha256"):
        if not isinstance(identity[field], str) or not re.fullmatch(r"[0-9a-f]{64}", identity[field]):
            raise ValueError(f"invalid recorded dependency identity: {field}")
    for field in ("sleigh_revision", "ghidra_revision"):
        if not isinstance(identity[field], str) or not re.fullmatch(r"[0-9a-f]{40}", identity[field]):
            raise ValueError(f"invalid recorded dependency identity: {field}")
    return identity


def toolchain_identity() -> dict[str, str]:
    compiler = output(["/usr/bin/xcrun", "--find", "clang++"])
    return {
        "compiler": compiler,
        "compiler_version": output([compiler, "--version"]),
        "sdk": output(["/usr/bin/xcrun", "--sdk", "macosx", "--show-sdk-path"]),
        "sdk_build": output(["/usr/bin/xcrun", "--sdk", "macosx", "--show-sdk-build-version"]),
    }


def build(root: Path, out: Path) -> Path:
    root = root.resolve(strict=True)
    if not out.is_absolute():
        raise ValueError("--out must be absolute")
    out = out.resolve()
    if out == root or root in out.parents:
        raise ValueError("--out must be outside the repository")
    package = root / "ThirdParty/SleighNative/package"
    library = package / "lib/libsla.a"
    headers = package / "include/sleigh/ghidra"
    if not library.is_file() or not headers.is_dir() or not (root / SOURCE).is_file():
        raise ValueError("governed SLEIGH package or CP1 source is not materialized")
    identity = {"schema_version": 1, "inputs": committed_inputs(root),
                "dependency": dependency_identity(root), "toolchain": toolchain_identity(),
                "flags": list(FLAGS)}
    encoded = json.dumps(identity, sort_keys=True, separators=(",", ":")) + "\n"
    # Hash only identity metadata, never source, library or toolchain payloads.
    key = hashlib.sha256(encoded.encode()).hexdigest()
    out.mkdir(parents=True, exist_ok=True)
    with (out / f"{key}.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        dest = out / key
        if dest.is_symlink():
            raise ValueError("CP1 cache entry must not be a symlink")
        dest.mkdir(exist_ok=True)
        executable = dest / "sleigh-lift"
        receipt = dest / "RECEIPT.json"
        if executable.exists() or receipt.exists() or executable.is_symlink() or receipt.is_symlink():
            if (executable.is_symlink() or receipt.is_symlink()
                    or not executable.is_file() or not os.access(executable, os.X_OK)
                    or not receipt.is_file() or receipt.read_text() != encoded):
                raise ValueError("CP1 cache entry lacks a matching executable and identity receipt")
            return executable
        descriptor, temporary = tempfile.mkstemp(prefix="sleigh-lift.", dir=dest)
        os.close(descriptor)
        try:
            toolchain = identity["toolchain"]
            subprocess.run([toolchain["compiler"], *FLAGS, "-isysroot", toolchain["sdk"],
                            "-I", str(headers), str(root / SOURCE), str(library), "-lz",
                            "-o", temporary], check=True, stdout=sys.stderr)
            if not os.access(temporary, os.X_OK):
                raise ValueError("CP1 compiler did not produce an executable")
            Path(temporary).replace(executable)
            receipt.write_text(encoded)
        finally:
            Path(temporary).unlink(missing_ok=True)
        return executable


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path,
                        default=Path.home() / "Library/Caches/MacScope/cp1-sleigh-lift")
    args = parser.parse_args()
    try:
        print(build(Path(__file__).resolve().parents[2], args.out))
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
