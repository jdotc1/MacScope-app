#!/usr/bin/env python3
"""Record an existing MacScope process with a named Instruments template under the heavy lock."""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import subprocess
import sys

from run_benchmark import command, external_path, hardware, heavy_lock, write_json


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-root", type=Path, required=True)
    parser.add_argument("--pid", type=int, required=True)
    parser.add_argument("--template", default="Time Profiler")
    parser.add_argument("--seconds", type=int, default=30)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if sys.platform != "darwin" or not 5 <= args.seconds <= 120 or args.pid <= 0:
        raise SystemExit("Use macOS, an existing PID and a 5...120 second duration")
    source = args.source_root.expanduser().resolve(strict=True)
    output = external_path(args.output, source)
    executable = command(["/bin/ps", "-p", str(args.pid), "-o", "comm="])
    if "MacScope" not in executable and "NativeDecompiler" not in executable and "AnalysisWorker" not in executable:
        raise SystemExit("PID must name MacScope or one of its workers")
    available = command(["/usr/bin/xcrun", "xctrace", "list", "templates"])
    if args.template not in available.splitlines() and args.template not in available:
        raise SystemExit("Template is unavailable; choose an exact entry from xcrun xctrace list templates")
    if "Processor Trace" in args.template:
        raise SystemExit("Processor Trace is not an M1 Max instrument; use Time Profiler/System Trace")
    output.mkdir(parents=True, exist_ok=False)
    write_json(output / "profile-context.json", {"schemaVersion": 1, "hardware": hardware(),
        "pid": args.pid, "executable": executable, "template": args.template, "seconds": args.seconds,
        "sourceCommit": command(["git", "rev-parse", "HEAD"], source),
        "installedSourceIdentityVerified": False,
        "note": "Bind the observed installed bundle to its existing release receipt before attributing this trace to a source commit."})
    with heavy_lock(source, output):
        result = subprocess.run(["/usr/bin/xcrun", "xctrace", "record", "--template", args.template,
            "--attach", str(args.pid), "--time-limit", str(args.seconds) + "s",
            "--output", str(output / "MacScope.trace")], check=False)
    raise SystemExit(result.returncode)


if __name__ == "__main__":
    main()
