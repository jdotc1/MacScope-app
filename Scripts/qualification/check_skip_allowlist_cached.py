#!/usr/bin/env python3
"""dev_loop's skip-allowlist gate: run Scripts/check_test_skip_allowlist.py only when a test file
or the allowlist changed since the last pass in this DerivedData (#379, #393 went red on main
because an opt-in test landed without its allowlist entry).

The fingerprint is (relative path, size, mtime_ns) of every Swift file under MacScope/Tests plus
the allowlist: ~20 ms, versus ~8 s for the lexical scan. Only a passing scan writes the stamp.

usage: check_skip_allowlist_cached.py <repo-root> <stamp-file>   exit 0 ok, 1 refused
"""
from __future__ import annotations

import hashlib
import os
from pathlib import Path
import subprocess
import sys


def fingerprint(root: Path) -> str:
    digest = hashlib.sha256()
    tests = root / "MacScope/Tests"
    paths = sorted(tests.rglob("*.swift")) + [root / "docs/qualification/skip-allowlist.json",
                                              root / "Scripts/check_test_skip_allowlist.py"]
    for path in paths:
        try:
            metadata = path.stat()
        except FileNotFoundError:
            continue
        digest.update(f"{path.relative_to(root)}\0{metadata.st_size}\0{metadata.st_mtime_ns}\n".encode())
    return digest.hexdigest()


def main(argv: list[str]) -> int:
    root, stamp = Path(argv[1]).resolve(), Path(argv[2])
    if not (root / "docs/qualification/skip-allowlist.json").exists():
        print("skip allowlist absent; check skipped")
        return 0
    current = fingerprint(root)
    try:
        if stamp.read_text(encoding="ascii").strip() == current:
            return 0
    except OSError:
        pass
    result = subprocess.run([sys.executable, "-B", str(root / "Scripts/check_test_skip_allowlist.py")],
                            stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
    if result.returncode != 0:
        sys.stderr.write(result.stderr)
        print("ERROR: skip allowlist check failed: add the entry to docs/qualification/skip-allowlist.json "
              "in the same PR (MACSCOPE_DEV_SKIP_ALLOWLIST_CHECK=1 skips this check)", file=sys.stderr)
        return 1
    stamp.parent.mkdir(parents=True, exist_ok=True)
    temporary = stamp.with_name(f".{stamp.name}.{os.getpid()}")
    temporary.write_text(current + "\n", encoding="ascii")
    os.replace(temporary, stamp)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
