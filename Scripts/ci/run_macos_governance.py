#!/usr/bin/env python3
"""Run the macOS complement of hosted governance, outside the native gate lease.

The shared exclusion inventory is authoritative: no second allowlist can drift
and leave a macOS-only module uncovered. These are Python contract/fixture
tests, not an application build, installation, or GUI acceptance run.
"""

from __future__ import annotations

import sys
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from Scripts.ci.run_hosted_governance import MACOS_ONLY_REASONS


def selected_modules() -> tuple[str, ...]:
    names = tuple(sorted(MACOS_ONLY_REASONS))
    if not names:
        raise ValueError("macOS governance selection is empty")
    missing = [name for name in names if not (ROOT / "Scripts/tests" / name).is_file()]
    if missing:
        raise ValueError(f"macOS governance modules are missing: {missing}")
    return tuple("Scripts.tests." + name.removesuffix(".py") for name in names)


def main() -> int:
    if sys.platform != "darwin":
        print("ERROR: macOS governance requires Darwin", file=sys.stderr)
        return 2
    started = time.monotonic()
    modules = selected_modules()
    for name in modules:
        print(f"macOS governance: {name}", flush=True)
    suite = unittest.defaultTestLoader.loadTestsFromNames(modules)
    if suite.countTestCases() == 0:
        print("ERROR: macOS governance contains no tests", file=sys.stderr)
        return 2
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    print(
        f"macOS governance: modules={len(modules)} ran={result.testsRun} "
        f"failures={len(result.failures)} errors={len(result.errors)} "
        f"skipped={len(result.skipped)} seconds={time.monotonic() - started:.2f}",
        flush=True,
    )
    # unittest prints every skip and its concrete reason; skips do not establish
    # coverage of that case. Preserve optional tool-dependent fixture behavior.
    return 0 if result.wasSuccessful() else 1


if __name__ == "__main__":
    raise SystemExit(main())
