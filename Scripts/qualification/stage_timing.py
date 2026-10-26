#!/usr/bin/env python3
"""Run qualification stages and append exact monotonic timing evidence."""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import time
from typing import Any


SCHEMA_VERSION = 1
HEX40 = re.compile(r"[0-9a-f]{40}")
STAGE = re.compile(r"[a-z0-9][a-z0-9._-]{0,127}")


class TimingError(RuntimeError):
    """Timing receipt state is malformed or belongs to another candidate."""


def canonical_json(value: object) -> bytes:
    return (
        json.dumps(
            value,
            ensure_ascii=True,
            allow_nan=False,
            sort_keys=True,
            separators=(",", ":"),
        )
        + "\n"
    ).encode("utf-8")


def object_without_duplicate_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise TimingError(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def load_receipt(path: Path) -> dict[str, Any]:
    if path.is_symlink():
        raise TimingError("timing receipt must not be a symbolic link")
    metadata = path.stat()
    if not stat.S_ISREG(metadata.st_mode) or metadata.st_nlink != 1:
        raise TimingError("timing receipt must be an ordinary single-link file")
    payload = path.read_bytes()
    try:
        value = json.loads(payload, object_pairs_hook=object_without_duplicate_keys)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise TimingError("timing receipt is malformed") from error
    if not isinstance(value, dict) or canonical_json(value) != payload:
        raise TimingError("timing receipt is not canonical JSON")
    return value


def expected_identity(arguments: argparse.Namespace) -> dict[str, object]:
    if HEX40.fullmatch(arguments.source_commit) is None or HEX40.fullmatch(arguments.source_tree) is None:
        raise TimingError("timing source identity is malformed")
    run_root = arguments.run_root.resolve(strict=True)
    return {
        "clock": "time.monotonic_ns",
        "mode": arguments.mode,
        "run_root": str(run_root),
        "schema_version": SCHEMA_VERSION,
        "source": {"commit": arguments.source_commit, "tree": arguments.source_tree},
        "stages": [],
    }


def validate_identity(value: dict[str, Any], expected: dict[str, object]) -> None:
    if set(value) != set(expected):
        raise TimingError("timing receipt field set differs")
    for key in ("clock", "mode", "run_root", "schema_version", "source"):
        if value.get(key) != expected[key]:
            raise TimingError(f"timing receipt {key} differs")
    if not isinstance(value.get("stages"), list):
        raise TimingError("timing receipt stages are malformed")


def write_receipt(path: Path, value: dict[str, Any]) -> None:
    temporary = path.with_name(path.name + f".tmp.{os.getpid()}")
    temporary.write_bytes(canonical_json(value))
    temporary.chmod(0o600)
    os.replace(temporary, path)


def init_command(arguments: argparse.Namespace) -> int:
    expected = expected_identity(arguments)
    if arguments.receipt.exists() or arguments.receipt.is_symlink():
        validate_identity(load_receipt(arguments.receipt), expected)
    else:
        arguments.receipt.parent.mkdir(parents=True, exist_ok=True)
        write_receipt(arguments.receipt, expected)
    return 0


def run_command(arguments: argparse.Namespace) -> int:
    if STAGE.fullmatch(arguments.stage) is None:
        raise TimingError("stage name is invalid")
    if not arguments.command:
        raise TimingError("timed stage command is missing")
    command = arguments.command
    if command[0] == "--":
        command = command[1:]
    if not command:
        raise TimingError("timed stage command is missing")
    receipt = load_receipt(arguments.receipt)
    stages = receipt.get("stages")
    if not isinstance(stages, list):
        raise TimingError("timing receipt stages are malformed")
    attempt = 1 + sum(
        isinstance(stage, dict) and stage.get("name") == arguments.stage for stage in stages
    )
    log_path: Path | None = None
    log_stream = None
    if arguments.combined_log is not None:
        log_path = arguments.combined_log
        if not log_path.is_absolute():
            raise TimingError("combined stage log path must be absolute")
        run_root = Path(receipt["run_root"])
        resolved_parent = log_path.parent.resolve(strict=True)
        try:
            resolved_parent.relative_to(run_root)
        except ValueError as error:
            raise TimingError("combined stage log must remain inside the run root") from error
        log_stream = log_path.open("ab")
    started_monotonic = time.monotonic_ns()
    started_wall = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
    return_code = 1
    try:
        if log_stream is None:
            completed = subprocess.run(command, check=False)
            return_code = completed.returncode
        else:
            process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
            assert process.stdout is not None
            while block := process.stdout.read(64 * 1024):
                log_stream.write(block)
                log_stream.flush()
                sys.stdout.buffer.write(block)
                sys.stdout.buffer.flush()
            return_code = process.wait()
    finally:
        if log_stream is not None:
            log_stream.close()
        ended_monotonic = time.monotonic_ns()
        stages.append(
            {
                "attempt": attempt,
                "duration_ns": ended_monotonic - started_monotonic,
                "ended_monotonic_ns": ended_monotonic,
                "exit_code": return_code,
                "log": str(log_path.resolve(strict=False)) if log_path is not None else None,
                "name": arguments.stage,
                "started_at": started_wall,
                "started_monotonic_ns": started_monotonic,
            }
        )
        write_receipt(arguments.receipt, receipt)
    return return_code


def record_command(arguments: argparse.Namespace) -> int:
    """Append a stage observed before this helper could run.

    Source admission runs before any run-source helper may execute, so the
    qualifier measures it with the system-wide CLOCK_MONOTONIC and records the
    completed observation here once the receipt exists.
    """
    if STAGE.fullmatch(arguments.stage) is None:
        raise TimingError("stage name is invalid")
    started = arguments.started_monotonic_ns
    ended = arguments.ended_monotonic_ns
    if started < 0 or ended < started:
        raise TimingError("recorded stage interval is invalid")
    try:
        started_wall = datetime.fromisoformat(arguments.started_at.replace("Z", "+00:00"))
    except ValueError as error:
        raise TimingError("recorded stage start time is malformed") from error
    if started_wall.tzinfo is None or not arguments.started_at.endswith("Z"):
        raise TimingError("recorded stage start time must be UTC")
    receipt = load_receipt(arguments.receipt)
    stages = receipt.get("stages")
    if not isinstance(stages, list):
        raise TimingError("timing receipt stages are malformed")
    attempt = 1 + sum(
        isinstance(stage, dict) and stage.get("name") == arguments.stage for stage in stages
    )
    stages.append(
        {
            "attempt": attempt,
            "duration_ns": ended - started,
            "ended_monotonic_ns": ended,
            "exit_code": arguments.exit_code,
            "log": None,
            "name": arguments.stage,
            "started_at": arguments.started_at,
            "started_monotonic_ns": started,
        }
    )
    write_receipt(arguments.receipt, receipt)
    return 0


def add_identity_arguments(command: argparse.ArgumentParser) -> None:
    command.add_argument("--receipt", type=Path, required=True)
    command.add_argument("--source-commit", required=True)
    command.add_argument("--source-tree", required=True)
    command.add_argument("--mode", required=True)
    command.add_argument("--run-root", type=Path, required=True)


def parser() -> argparse.ArgumentParser:
    value = argparse.ArgumentParser()
    commands = value.add_subparsers(dest="operation", required=True)
    initialize = commands.add_parser("init")
    add_identity_arguments(initialize)
    initialize.set_defaults(action=init_command)
    run = commands.add_parser("run")
    run.add_argument("--receipt", type=Path, required=True)
    run.add_argument("--stage", required=True)
    run.add_argument("--combined-log", type=Path)
    run.add_argument("command", nargs=argparse.REMAINDER)
    run.set_defaults(action=run_command)
    record = commands.add_parser("record")
    record.add_argument("--receipt", type=Path, required=True)
    record.add_argument("--stage", required=True)
    record.add_argument("--started-at", required=True)
    record.add_argument("--started-monotonic-ns", type=int, required=True)
    record.add_argument("--ended-monotonic-ns", type=int, required=True)
    record.add_argument("--exit-code", type=int, required=True)
    record.set_defaults(action=record_command)
    return value


def main() -> int:
    arguments = parser().parse_args()
    try:
        return arguments.action(arguments)
    except (OSError, subprocess.SubprocessError, TimingError, ValueError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
