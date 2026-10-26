#!/usr/bin/env python3
"""Build-economics receipt support with a semantic Xcode script-phase inventory."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import platform
import re
import subprocess
import sys
from typing import Any


PHASE_NAME = re.compile(r"^- name:\s*(.+?)\s*$")
DEPENDENCY_FLAG = re.compile(r"^basedOnDependencyAnalysis:\s*(true|false)\s*$")
TIMING_LINE = re.compile(r"^\s*(.+?)\s+\|\s+([0-9]+(?:\.[0-9]+)?) seconds\s*$")


def project_script_phase_inventory(project_text: str) -> list[dict[str, Any]]:
    """Extract target/name/dependency-analysis triples without a YAML dependency."""
    in_targets = False
    target: str | None = None
    phase_kind: str | None = None
    pending: dict[str, Any] | None = None
    phases: list[dict[str, Any]] = []

    def finish_pending() -> None:
        nonlocal pending
        if pending is None:
            return
        if "basedOnDependencyAnalysis" not in pending:
            raise ValueError(
                f"script phase {pending['target']}/{pending['name']} lacks "
                "basedOnDependencyAnalysis"
            )
        phases.append(pending)
        pending = None

    for raw_line in project_text.splitlines():
        stripped = raw_line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        indentation = len(raw_line) - len(raw_line.lstrip(" "))
        if indentation == 0:
            if stripped == "targets:":
                in_targets = True
                continue
            if in_targets:
                finish_pending()
                break
        if not in_targets:
            continue
        if indentation == 2 and stripped.endswith(":"):
            finish_pending()
            target = stripped[:-1]
            phase_kind = None
            continue
        if indentation == 4:
            finish_pending()
            phase_kind = stripped[:-1] if stripped in {"preBuildScripts:", "postBuildScripts:"} else None
            continue
        if target is None or phase_kind is None:
            continue
        if indentation == 6:
            match = PHASE_NAME.fullmatch(stripped)
            if match:
                finish_pending()
                pending = {
                    "kind": phase_kind,
                    "name": match.group(1).strip('"\''),
                    "target": target,
                }
            continue
        if indentation == 8 and pending is not None:
            match = DEPENDENCY_FLAG.fullmatch(stripped)
            if match:
                pending["basedOnDependencyAnalysis"] = match.group(1) == "true"
    finish_pending()
    return phases


def build_timing_summary(log_text: str) -> list[dict[str, Any]]:
    marker = "Build Timing Summary"
    if marker not in log_text:
        return []
    summary = log_text.rsplit(marker, maxsplit=1)[1]
    rows: list[dict[str, Any]] = []
    for line in summary.splitlines():
        match = TIMING_LINE.fullmatch(line)
        if match:
            rows.append({"task": match.group(1).strip(), "seconds": float(match.group(2))})
    return rows


def command_output(command: list[str]) -> str:
    return subprocess.run(command, check=True, capture_output=True, text=True).stdout.strip()


def optional_command_output(command: list[str]) -> str | None:
    try:
        return command_output(command)
    except (OSError, subprocess.CalledProcessError):
        return None


def host_metadata() -> dict[str, Any]:
    return {
        "architecture": platform.machine(),
        "hardwareModel": optional_command_output(["/usr/sbin/sysctl", "-n", "hw.model"]),
        "logicalCPUCount": os.cpu_count(),
        "macOSVersion": platform.mac_ver()[0],
    }


def toolchain_metadata() -> dict[str, str]:
    lines = command_output(["/usr/bin/xcodebuild", "-version"]).splitlines()
    return {
        "xcodeBuild": lines[1].removeprefix("Build version ") if len(lines) > 1 else "",
        "xcodeVersion": lines[0].removeprefix("Xcode ") if lines else "",
    }


def write_receipt(arguments: argparse.Namespace) -> None:
    project_text = arguments.project_yml.read_text(encoding="utf-8")
    receipt = {
        "gitHead": command_output(["/usr/bin/git", "-C", str(arguments.repository_root), "rev-parse", "HEAD"]),
        "host": host_metadata(),
        "invocation": {
            "configuration": "Debug",
            "destination": "platform=macOS,arch=arm64",
            "indexStoreEnabled": False,
            "project": "MacScope/MacScope.xcodeproj",
            "scheme": "MacScopeApp",
            "showBuildTimingSummary": True,
        },
        "measuredAtUTC": arguments.measured_at_utc,
        "measurementScope": "host-specific-observation",
        "measurements": {
            "cold": {
                "seconds": arguments.cold_seconds,
                "timingSummary": build_timing_summary(arguments.cold_log.read_text(encoding="utf-8", errors="replace")),
            },
            "null": {
                "seconds": arguments.null_seconds,
                "timingSummary": build_timing_summary(arguments.null_log.read_text(encoding="utf-8", errors="replace")),
            },
        },
        "schemaVersion": 1,
        "scriptPhases": project_script_phase_inventory(project_text),
        "threshold": None,
        "toolchain": toolchain_metadata(),
    }
    arguments.output.parent.mkdir(parents=True, exist_ok=True)
    arguments.output.write_text(json.dumps(receipt, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def parse_arguments(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repository-root", type=Path, required=True)
    parser.add_argument("--project-yml", type=Path, required=True)
    parser.add_argument("--cold-log", type=Path, required=True)
    parser.add_argument("--null-log", type=Path, required=True)
    parser.add_argument("--cold-seconds", type=float, required=True)
    parser.add_argument("--null-seconds", type=float, required=True)
    parser.add_argument("--measured-at-utc", required=True)
    parser.add_argument("--output", type=Path, required=True)
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    write_receipt(parse_arguments(sys.argv[1:] if argv is None else argv))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
