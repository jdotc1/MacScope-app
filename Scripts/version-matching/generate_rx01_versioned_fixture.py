#!/usr/bin/env python3
"""Build the RX-01 two-version real-binary fixture, or check the committed one.

Compiles ``MacScope/Tests/Fixtures/RX01Versioned/rx01_versioned.c`` with the selected Xcode
clang into seven thin arm64 Mach-O executables and writes ``manifest.json`` beside them:

  rx01_v1                  named v1
  rx01_v2                  named v2 (added_fn first, so every v1 function moves; checksum constant
                           changed; old_name renamed new_name; leaf_called_once body changed;
                           removed_fn gone)
  rx01_v1_stripped         ``strip`` of rx01_v1 (only __mh_execute_header remains)
  rx01_v2_stripped         ``strip`` of rx01_v2
  rx01_v2_inlined          v2 with leaf_called_once forced inline into parse_header
  rx01_v2_merged           v2 linked with -Wl,-deduplicate, so helper_a/helper_b fold to one body
  rx01_v2_merged_stripped  ``strip`` of rx01_v2_merged

The builds are deterministic for a given toolchain (no debug info, fixed output names, ad-hoc
linker signature over identical bytes). ``CoreTests/AnnotationTransferRealBinaryTests`` reads the
committed binaries through ``#filePath`` and asserts the expected match table, so the tests never
need a compiler at run time.

Usage:
  generate_rx01_versioned_fixture.py           rebuild and overwrite binaries + manifest
  generate_rx01_versioned_fixture.py --check   verify source/generator hashes and committed bytes,
                                               then rebuild in a temporary directory and require
                                               byte-identical output (exit 1 on any difference)

Standard library only; Python 3.9+.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Dict, List, Optional

ROOT = Path(__file__).resolve().parents[2]
FIXTURE_DIR = ROOT / "MacScope" / "Tests" / "Fixtures" / "RX01Versioned"
SOURCE = FIXTURE_DIR / "rx01_versioned.c"
MANIFEST = FIXTURE_DIR / "manifest.json"
GENERATOR = Path(__file__).resolve()
SCHEMA = "macscope.rx01-versioned-fixture.v1"

BASE_FLAGS = [
    "-arch", "arm64",
    "-mmacosx-version-min=27.0",
    "-O1",
    "-fno-inline",
    "-fno-optimize-sibling-calls",
]
V2 = ["-DRX01_V2"]
INLINE_LEAF = ["-DRX01_LEAF_ATTR=static inline __attribute__((always_inline))"]
DEDUPLICATE = ["-Wl,-deduplicate"]

# (name, compile flags or None, stripped-from variant or None)
VARIANTS = [
    ("rx01_v1", BASE_FLAGS, None),
    ("rx01_v2", BASE_FLAGS + V2, None),
    ("rx01_v1_stripped", None, "rx01_v1"),
    ("rx01_v2_stripped", None, "rx01_v2"),
    ("rx01_v2_inlined", BASE_FLAGS + V2 + INLINE_LEAF, None),
    ("rx01_v2_merged", BASE_FLAGS + V2 + DEDUPLICATE, None),
    ("rx01_v2_merged_stripped", None, "rx01_v2_merged"),
]


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def run(arguments: List[str], cwd: Optional[Path] = None) -> str:
    completed = subprocess.run(arguments, cwd=cwd, check=False, stdout=subprocess.PIPE,
                               stderr=subprocess.STDOUT, universal_newlines=True)
    if completed.returncode != 0:
        raise SystemExit("ERROR: {} failed ({}):\n{}".format(" ".join(arguments), completed.returncode,
                                                              completed.stdout))
    return completed.stdout


def toolchain() -> Dict[str, str]:
    return {
        "clang": run(["/usr/bin/xcrun", "clang", "--version"]).splitlines()[0].strip(),
        "ld": next((line.strip() for line in run(["/usr/bin/xcrun", "ld", "-v"]).splitlines()
                    if line.startswith("@(#)PROGRAM:ld")), "unknown"),
        "sdk": run(["/usr/bin/xcrun", "--sdk", "macosx", "--show-sdk-version"]).strip(),
    }


def build(output_dir: Path) -> List[Dict[str, object]]:
    """Builds every variant into ``output_dir`` (under the final file names) and describes them."""
    records = []
    for name, flags, stripped_from in VARIANTS:
        destination = output_dir / name
        if stripped_from is None:
            # Compile from inside the output directory so the only path the driver sees is the
            # final output name (the ad-hoc signature identifier is derived from it).
            run(["/usr/bin/xcrun", "clang"] + list(flags) + ["-o", name, str(SOURCE)], cwd=output_dir)
            record = {"name": name, "flags": list(flags)}
        else:
            run(["/usr/bin/xcrun", "strip", "-o", name, stripped_from], cwd=output_dir)
            record = {"name": name, "strip_of": stripped_from}
        record["sha256"] = sha256(destination)
        record["size"] = destination.stat().st_size
        records.append(record)
    return records


def manifest(records: List[Dict[str, object]]) -> Dict[str, object]:
    return {
        "schema": SCHEMA,
        "source": {"path": SOURCE.name, "sha256": sha256(SOURCE)},
        "generator": {"path": str(GENERATOR.relative_to(ROOT)), "sha256": sha256(GENERATOR)},
        "toolchain": toolchain(),
        "variants": records,
    }


def write() -> int:
    with tempfile.TemporaryDirectory(prefix="rx01-fixture-") as scratch:
        records = build(Path(scratch))
        for record in records:
            target = FIXTURE_DIR / str(record["name"])
            shutil.copyfile(Path(scratch) / str(record["name"]), target)
            os.chmod(target, 0o755)
    MANIFEST.write_text(json.dumps(manifest(records), indent=2, sort_keys=True) + "\n")
    print("wrote {} variants and {}".format(len(records), MANIFEST.relative_to(ROOT)))
    return 0


def check() -> int:
    problems: List[str] = []
    try:
        recorded = json.loads(MANIFEST.read_text())
    except (OSError, ValueError) as error:
        print("FAIL: cannot read {}: {}".format(MANIFEST, error))
        return 1
    if recorded.get("schema") != SCHEMA:
        problems.append("manifest schema {!r} != {!r}".format(recorded.get("schema"), SCHEMA))
    if recorded.get("source", {}).get("sha256") != sha256(SOURCE):
        problems.append("source changed since the fixture was generated")
    if recorded.get("generator", {}).get("sha256") != sha256(GENERATOR):
        problems.append("generator changed since the fixture was generated")
    expected_names = [name for name, _, _ in VARIANTS]
    recorded_variants = {variant.get("name"): variant for variant in recorded.get("variants", [])}
    if sorted(recorded_variants) != sorted(expected_names):
        problems.append("manifest variants {} != {}".format(sorted(recorded_variants), sorted(expected_names)))
    for name in expected_names:
        committed = FIXTURE_DIR / name
        if not committed.is_file() or committed.is_symlink():
            problems.append("{}: missing or not a regular file".format(name))
        elif sha256(committed) != recorded_variants.get(name, {}).get("sha256"):
            problems.append("{}: committed bytes differ from the manifest".format(name))

    current_toolchain = toolchain()
    with tempfile.TemporaryDirectory(prefix="rx01-fixture-check-") as scratch:
        for record in build(Path(scratch)):
            name = str(record["name"])
            committed = FIXTURE_DIR / name
            if committed.is_file() and sha256(committed) != record["sha256"]:
                problems.append("{}: rebuild is not byte-identical to the committed binary".format(name))
    if problems and current_toolchain != recorded.get("toolchain"):
        problems.append("toolchain drift: recorded {} vs current {}; regenerate and re-derive the "
                        "expected match table".format(recorded.get("toolchain"), current_toolchain))
    if problems:
        for problem in problems:
            print("FAIL: " + problem)
        return 1
    print("OK: {} variants verified and rebuilt byte-identically ({}; {}; SDK {})".format(
        len(expected_names), current_toolchain["clang"], current_toolchain["ld"], current_toolchain["sdk"]))
    return 0


def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--check", action="store_true",
                        help="verify the committed fixture and require a byte-identical rebuild")
    arguments = parser.parse_args(argv)
    if sys.platform != "darwin":
        print("ERROR: the fixture is built with Apple clang/ld and needs macOS", file=sys.stderr)
        return 2
    return check() if arguments.check else write()


if __name__ == "__main__":
    sys.exit(main())
