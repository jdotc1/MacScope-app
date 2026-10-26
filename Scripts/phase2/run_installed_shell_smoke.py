#!/usr/bin/env python3
"""Run MacScope's opt-in installed Phase 2 shell smoke.

This script does not use Accessibility or XCUITest. It launches the selected
MacScope.app executable with an environment variable that asks the app to run its
own ShellBroker smoke before SwiftUI scene creation, write a bounded JSON report,
and exit.
"""

from __future__ import annotations

import argparse
import ctypes
import hashlib
import json
import os
import subprocess
import stat
import sys
import tempfile
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, NoReturn


EXECUTABLE_NAME = "MacScope"
REPORT_ENV = "MACSCOPE_PHASE2_INSTALLED_SHELL_SMOKE_REPORT"
MARKER_ENV = "MACSCOPE_PHASE2_INSTALLED_SHELL_SMOKE_MARKER"
TIMEOUT_ENV = "MACSCOPE_PHASE2_INSTALLED_SHELL_SMOKE_TIMEOUT_SECONDS"
MODE_ENV = "MACSCOPE_PHASE2_INSTALLED_SHELL_SMOKE_MODE"
RENDEZVOUS_ENV = "MACSCOPE_PHASE2_INSTALLED_SHELL_SMOKE_RENDEZVOUS"
STOP_SENTINEL_ENV = "MACSCOPE_PHASE2_INSTALLED_SHELL_SMOKE_STOP_SENTINEL"
RENDERER_MODE_ENV = "MACSCOPE_PHASE2_INSTALLED_SHELL_SMOKE_RENDERER_MODE"
PROVENANCE_NAME = "MacScopeBuildProvenance.json"
REPORT_SCHEMA_VERSION = 5
DEFAULT_FULL_SURFACE_MODE = "defaultFullGhosttySurface"
FORCED_LEGACY_GRID_MODE = "forcedLegacyGridRecoveryOverride"
MAXIMUM_PROVENANCE_BYTES = 1024 * 1024
OLD_DETACHED_GRACE_SECONDS = 120.0
MAXIMUM_LOG_BYTES = 64 * 1024


class SmokeError(RuntimeError):
    pass


def fail(message: str) -> NoReturn:
    raise SmokeError(message)


def parse_arguments(arguments: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--app",
        type=Path,
        default=Path("/Applications/MacScope.app"),
        help="Installed MacScope.app bundle to smoke.",
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=None,
        help="Destination report JSON. Defaults to a temporary file.",
    )
    parser.add_argument(
        "--marker",
        default="macscope-installed-shell-smoke",
        help="Unique marker written through the shell.",
    )
    parser.add_argument(
        "--timeout-seconds",
        type=float,
        default=15.0,
        help="Process timeout for the installed app smoke.",
    )
    parser.add_argument(
        "--single-launch",
        action="store_true",
        help="Run the legacy single-launch smoke instead of the two-launch restart gate.",
    )
    parser.add_argument(
        "--restart-wait-seconds",
        type=float,
        default=OLD_DETACHED_GRACE_SECONDS + 1.0,
        help="Delay between PREPARE termination and RESUME (must exceed 120 seconds).",
    )
    parser.add_argument(
        "--expected-source-commit",
        default=None,
        help=(
            "Exact 40-hex candidate commit required for execution and installed "
            "Release provenance admission."
        ),
    )
    return parser.parse_args(arguments)


def executable_url(app: Path) -> Path:
    return app / "Contents" / "MacOS" / EXECUTABLE_NAME


def shell_broker_url(app: Path) -> Path:
    return (
        app
        / "Contents"
        / "XPCServices"
        / "ShellBrokerXPCService.xpc"
        / "Contents"
        / "MacOS"
        / "ShellBrokerXPCService"
    )


def provenance_url(app: Path) -> Path:
    return app / "Contents" / "Resources" / PROVENANCE_NAME


def validate_app(app: Path) -> tuple[Path, Path]:
    if not app.is_absolute():
        fail("--app must be an absolute path")
    if app.is_symlink() or not app.is_dir() or app.suffix != ".app":
        fail(f"app must be an existing non-symlink .app bundle: {app}")
    executable = executable_url(app)
    broker = shell_broker_url(app)
    if executable.is_symlink() or not executable.is_file():
        fail(f"MacScope executable is missing or invalid: {executable}")
    if broker.is_symlink() or not broker.is_file():
        fail(f"ShellBroker executable is missing or invalid: {broker}")
    return executable, broker


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def is_lowercase_hex(value: Any, length: int) -> bool:
    return (
        isinstance(value, str)
        and len(value) == length
        and all(character in "0123456789abcdef" for character in value)
    )


def load_build_identity(
    app: Path,
    expected_source_commit: str | None,
) -> dict[str, str]:
    if expected_source_commit is not None and not is_lowercase_hex(
        expected_source_commit, 40
    ):
        fail("--expected-source-commit must be a lowercase 40-hex Git object ID")
    path = provenance_url(app)
    try:
        metadata = path.lstat()
    except OSError as error:
        fail(f"installed Release provenance is missing: {error}")
    if (
        path.is_symlink()
        or not stat.S_ISREG(metadata.st_mode)
        or metadata.st_nlink != 1
        or metadata.st_size <= 0
        or metadata.st_size > MAXIMUM_PROVENANCE_BYTES
    ):
        fail("installed Release provenance must be one bounded ordinary singly linked file")
    payload = load_report(path)
    installed_source_commit = payload.get("git_head_commit")
    source_tree = payload.get("git_head_tree")
    if (
        payload.get("schema_version") != 1
        or payload.get("qualification_eligible") is not True
        or payload.get("configuration") != "Release"
        or not is_lowercase_hex(installed_source_commit, 40)
        or (
            expected_source_commit is not None
            and installed_source_commit != expected_source_commit
        )
        or not is_lowercase_hex(source_tree, 40)
        or payload.get("repository_clean") is not True
        or payload.get("ghostty_surface_compilation_condition")
        != "MACSCOPE_FULL_GHOSTTY_SURFACE"
    ):
        fail("installed Release provenance does not match the exact renderer candidate")
    return {
        "sourceCommit": installed_source_commit,
        "sourceTree": source_tree,
        "buildProvenanceSHA256": sha256_file(path),
    }


def canonical_uuid(value: Any) -> bool:
    if not isinstance(value, str):
        return False
    try:
        return str(uuid.UUID(value)) == value
    except ValueError:
        return False


def validate_renderer_evidence(
    report: dict[str, Any],
    build_identity: dict[str, str],
    requested_mode: str,
) -> None:
    for field, expected in build_identity.items():
        if report.get(field) != expected:
            fail(f"smoke report {field} does not match installed Release provenance")
    evidence = report.get("rendererEvidence")
    required_fields = {
        "requestedMode",
        "selectedBackend",
        "fallbackReason",
        "rendererPresented",
        "transcriptOnlyFallbackPresented",
        "shellSessionID",
        "shellRequestID",
        "shellProcessIdentifier",
    }
    if not isinstance(evidence, dict) or set(evidence) != required_fields:
        fail("smoke report renderer evidence is missing or not a closed record")
    expected = {
        DEFAULT_FULL_SURFACE_MODE: ("ghosttyFullSurface", None),
        FORCED_LEGACY_GRID_MODE: ("macScopeGhosttyVTGrid", "recoveryOverride"),
    }.get(requested_mode)
    if expected is None or evidence.get("requestedMode") != requested_mode:
        fail("smoke report renderer request does not match the launched mode")
    if evidence.get("selectedBackend") != expected[0] or evidence.get("fallbackReason") != expected[1]:
        fail("smoke report did not prove the requested renderer backend")
    if evidence.get("rendererPresented") is not True:
        fail("smoke report did not prove renderer presentation")
    if evidence.get("transcriptOnlyFallbackPresented") is not False:
        fail("transcript-only fallback cannot satisfy installed renderer proof")
    if not canonical_uuid(evidence.get("shellSessionID")) or not canonical_uuid(
        evidence.get("shellRequestID")
    ):
        fail("smoke report renderer evidence omitted exact shell session identity")
    if evidence.get("shellProcessIdentifier") != report.get("launchedProcessIdentifier"):
        fail("smoke report renderer evidence does not match the ShellBroker process")


def load_report(path: Path) -> dict[str, Any]:
    try:
        with path.open("r", encoding="utf-8") as handle:
            payload = json.load(handle)
    except OSError as error:
        fail(f"could not read smoke report {path}: {error}")
    except json.JSONDecodeError as error:
        fail(f"could not parse smoke report {path}: {error}")
    if not isinstance(payload, dict):
        fail("smoke report must be a JSON object")
    return payload


def validate_common_report(
    report: dict[str, Any],
    executable: Path,
    marker: str,
    build_identity: dict[str, str],
    requested_renderer_mode: str,
) -> None:
    if report.get("schemaVersion") != REPORT_SCHEMA_VERSION:
        fail("smoke report schemaVersion mismatch")
    if report.get("status") != "passed":
        fail(f"smoke report did not pass: {report.get('error')}")
    if report.get("appExecutablePath") != str(executable):
        fail("smoke report executable path does not match launched executable")
    if report.get("appExecutableSHA256") != sha256_file(executable):
        fail("smoke report executable digest does not match launched executable")
    if report.get("shellBrokerServiceIdentifier") != "terminal.human_pty.shell_broker":
        fail("smoke report ShellBroker service identifier mismatch")
    if report.get("shellBrokerWireProtocol") != "macscope.phase2.shell_broker.xpc.v4":
        fail("smoke report ShellBroker wire protocol mismatch")
    required_commands = {
        "launchProcess",
        "cleanupProcess",
        "writeInput",
        "resizeTerminal",
        "sendSignal",
        "pollTranscript",
        "reconnectSession",
        "launchDurableProcess",
        "commitDurableSession",
        "durableSessionStatus",
        "attachDurableSession",
        "detachDurableSession",
        "heartbeatDurableSession",
    }
    if set(report.get("supportedCommands") or []) != required_commands:
        fail("smoke report supported command set mismatch")
    if not isinstance(report.get("launchedProcessIdentifier"), int) or report["launchedProcessIdentifier"] <= 1:
        fail("smoke report did not record a valid launched process identifier")
    validate_renderer_evidence(report, build_identity, requested_renderer_mode)


def validate_single_report(
    report: dict[str, Any],
    executable: Path,
    marker: str,
    build_identity: dict[str, str],
    requested_renderer_mode: str,
) -> None:
    validate_common_report(
        report, executable, marker, build_identity, requested_renderer_mode
    )
    observed_reply = report.get("observedReply")
    if not isinstance(observed_reply, str) or f"reply:{marker}" not in observed_reply:
        fail("smoke report did not contain the expected shell reply")
    if not isinstance(report.get("acceptedTranscriptEventCount"), int) or report["acceptedTranscriptEventCount"] < 2:
        fail("smoke report did not record enough accepted transcript events")
    if report.get("reconnectAcceptedTranscriptEventCount") != 1:
        fail("smoke report did not prove exactly one app-owned reconnect event")
    if report.get("cleanupObservedProcessAbsent") is not True:
        fail("smoke report did not prove cleanup observed the shell process absent")


def validate_restart_report(
    report: dict[str, Any],
    executable: Path,
    marker: str,
    mode: str,
    build_identity: dict[str, str],
    requested_renderer_mode: str,
) -> None:
    validate_common_report(
        report, executable, marker, build_identity, requested_renderer_mode
    )
    if report.get("mode") != mode:
        fail(f"restart report mode mismatch: expected {mode}")
    if not isinstance(report.get("brokerIncarnationID"), str):
        fail("restart report omitted broker incarnation")
    if not isinstance(report.get("processStartTimeUnixNanoseconds"), int) or report["processStartTimeUnixNanoseconds"] <= 0:
        fail("restart report omitted process start time")
    if report.get("executablePath") != "/bin/sh":
        fail("restart report executable identity mismatch")
    if not isinstance(report.get("processGroupIdentifier"), int) or report["processGroupIdentifier"] <= 1:
        fail("restart report process-group identity mismatch")
    cursor = report.get("transcriptCursor")
    if not isinstance(cursor, int) or cursor < 1:
        fail("restart report cursor mismatch")
    expected_buffered_marker = f"detached:{marker}"
    if mode == "PREPARE":
        if cursor != 1:
            fail("PREPARE restart report cursor mismatch")
        if report.get("bufferedMarker") is not None or report.get("bufferedMarkerAcceptedCount") != 0:
            fail("PREPARE unexpectedly accepted the detached transcript marker")
        if report.get("transcriptCursorAdvanced") is not False:
            fail("PREPARE unexpectedly reported an advanced transcript cursor")
    elif mode == "RESUME":
        if cursor <= 1:
            fail("RESUME transcript cursor did not advance")
        if report.get("bufferedMarker") != expected_buffered_marker:
            fail("RESUME report omitted the exact detached transcript marker")
        if report.get("observedReply") != expected_buffered_marker:
            fail("RESUME report did not observe the exact detached transcript marker")
        if report.get("bufferedMarkerAcceptedCount") != 1:
            fail("RESUME did not accept the detached transcript marker exactly once")
        if not isinstance(report.get("acceptedTranscriptEventCount"), int) or report["acceptedTranscriptEventCount"] < 1:
            fail("RESUME did not accept buffered transcript events")
        if report.get("transcriptCursorAdvanced") is not True:
            fail("RESUME did not prove transcript cursor advancement")
    expected_cleanup = mode in ("RESUME", "CLEANUP")
    if report.get("cleanupObservedProcessAbsent") is not expected_cleanup:
        fail("restart report cleanup proof mismatch")
    if report.get("capabilityRemoved") is not expected_cleanup:
        fail("restart report Keychain cleanup proof mismatch")
    if report.get("rendezvousRemoved") is not expected_cleanup:
        fail("restart report rendezvous cleanup proof mismatch")


def process_executable_path(process_identifier: int) -> Path | None:
    """Return the kernel-reported executable path for one exact PID."""
    library = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
    buffer = ctypes.create_string_buffer(4096)
    length = library.proc_pidpath(process_identifier, buffer, len(buffer))
    if length <= 0:
        return None
    return Path(os.fsdecode(buffer.value))


def process_start_identity(process_identifier: int) -> str | None:
    class ProcBSDInfo(ctypes.Structure):
        _fields_ = [
            ("flags", ctypes.c_uint32), ("status", ctypes.c_uint32),
            ("xstatus", ctypes.c_uint32), ("pid", ctypes.c_uint32),
            ("ppid", ctypes.c_uint32), ("uid", ctypes.c_uint32),
            ("gid", ctypes.c_uint32), ("ruid", ctypes.c_uint32),
            ("rgid", ctypes.c_uint32), ("svuid", ctypes.c_uint32),
            ("svgid", ctypes.c_uint32), ("rfu_1", ctypes.c_uint32),
            ("comm", ctypes.c_char * 16), ("name", ctypes.c_char * 32),
            ("nfiles", ctypes.c_uint32), ("pgid", ctypes.c_uint32),
            ("pjobc", ctypes.c_uint32), ("e_tdev", ctypes.c_uint32),
            ("e_tpgid", ctypes.c_uint32), ("nice", ctypes.c_int32),
            ("start_tvsec", ctypes.c_uint64), ("start_tvusec", ctypes.c_uint64),
        ]

    information = ProcBSDInfo()
    library = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
    PROC_PIDTBSDINFO = 3
    length = library.proc_pidinfo(
        process_identifier, PROC_PIDTBSDINFO, 0,
        ctypes.byref(information), ctypes.sizeof(information),
    )
    if length != ctypes.sizeof(information) or information.pid != process_identifier:
        return None
    return f"{information.start_tvsec}:{information.start_tvusec}"


def wait_for_report(path: Path, process: subprocess.Popen[str], timeout: float) -> dict[str, Any]:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if path.is_file():
            return load_report(path)
        return_code = process.poll()
        if return_code is not None:
            fail(f"PREPARE app exited before reporting (status {return_code})")
        time.sleep(0.05)
    fail("timed out waiting for PREPARE report")


def create_cooperative_stop(path: Path) -> None:
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW
    try:
        descriptor = os.open(path, flags, 0o600)
    except OSError as error:
        fail(f"could not atomically create cooperative stop sentinel: {error}")
    os.close(descriptor)
    if path.is_symlink() or path.stat().st_mode & 0o777 != 0o600:
        fail("cooperative stop sentinel identity mismatch")


def stop_prepare_cooperatively(process: subprocess.Popen[str], sentinel: Path) -> None:
    if process.poll() is not None:
        return
    if not sentinel.exists():
        create_cooperative_stop(sentinel)
    elif sentinel.is_symlink() or sentinel.stat().st_mode & 0o777 != 0o600:
        fail("existing cooperative stop sentinel identity mismatch")
    try:
        return_code = process.wait(timeout=10.0)
    except subprocess.TimeoutExpired as error:
        fail(f"PREPARE did not honor cooperative stop sentinel: {error}")
    if return_code != 0:
        fail(f"cooperatively stopped PREPARE reaped with status {return_code}")


def secure_rendezvous_exists(path: Path) -> bool:
    try:
        metadata = path.lstat()
    except FileNotFoundError:
        return False
    return stat.S_ISREG(metadata.st_mode) and not path.is_symlink() and metadata.st_mode & 0o777 == 0o600


def capture_bounded_logs(
    start: datetime, destination: Path, marker: str, process_identifiers: set[int]
) -> None:
    pid_clause = " OR ".join(
        f"processIdentifier == {value}" for value in sorted(process_identifiers) if value > 1
    )
    if not pid_clause:
        fail("cannot capture restart logs without exact process identifiers")
    command = [
        "/usr/bin/log", "show", "--style", "json", "--start",
        start.astimezone().strftime("%Y-%m-%d %H:%M:%S"),
        "--predicate", f'({pid_clause}) AND eventMessage CONTAINS {json.dumps(marker)}',
    ]
    result = subprocess.run(command, capture_output=True, timeout=15.0, check=False)
    if result.returncode != 0 or not result.stdout:
        fail(f"bounded unified log capture failed with status {result.returncode}")
    bounded = result.stdout[-MAXIMUM_LOG_BYTES:]
    try:
        descriptor = os.open(
            destination, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600
        )
    except OSError as error:
        fail(f"could not atomically create bounded log artifact: {error}")
    try:
        os.write(descriptor, bounded)
    finally:
        os.close(descriptor)


def run_smoke(arguments: argparse.Namespace) -> dict[str, Any]:
    executable, broker = validate_app(arguments.app)
    build_identity = load_build_identity(arguments.app, arguments.expected_source_commit)
    output = arguments.output
    if output is None:
        output = Path(tempfile.mkdtemp(prefix="macscope-installed-shell-smoke.")) / "installed-shell-smoke.json"
    if not output.is_absolute():
        fail("--output must be an absolute path when supplied")
    output.parent.mkdir(parents=True, exist_ok=True)
    legacy_output = output.with_name(f"{output.stem}.legacy-grid{output.suffix}")
    for destination in (output, legacy_output):
        if destination.exists() or destination.is_symlink():
            fail(f"refusing to overwrite existing smoke report: {destination}")

    def launch(destination: Path, renderer_mode: str) -> None:
        environment = os.environ.copy()
        environment[REPORT_ENV] = str(destination)
        environment[MARKER_ENV] = arguments.marker
        environment[TIMEOUT_ENV] = str(max(1.0, min(arguments.timeout_seconds, 30.0)))
        environment[RENDERER_MODE_ENV] = renderer_mode
        result = subprocess.run(
            [str(executable)],
            cwd=str(arguments.app.parent),
            env=environment,
            text=True,
            capture_output=True,
            timeout=arguments.timeout_seconds + 5.0,
            check=False,
        )
        if result.returncode != 0:
            fail(
                f"installed app shell smoke ({renderer_mode}) exited "
                f"{result.returncode}; stdout={result.stdout[-400:]!r}; "
                f"stderr={result.stderr[-400:]!r}"
            )
        validate_single_report(
            load_report(destination),
            executable,
            arguments.marker,
            build_identity,
            renderer_mode,
        )

    launch(output, DEFAULT_FULL_SURFACE_MODE)
    launch(legacy_output, FORCED_LEGACY_GRID_MODE)
    return {
        "accepted": True,
        "app": str(arguments.app),
        "brokerExecutableSHA256": sha256_file(broker),
        **build_identity,
        "report": str(output),
        "reportSHA256": sha256_file(output),
        "legacyGridReport": str(legacy_output),
        "legacyGridReportSHA256": sha256_file(legacy_output),
    }


def run_restart_smoke(arguments: argparse.Namespace) -> dict[str, Any]:
    executable, broker = validate_app(arguments.app)
    build_identity = load_build_identity(arguments.app, arguments.expected_source_commit)
    if arguments.restart_wait_seconds <= OLD_DETACHED_GRACE_SECONDS:
        fail("--restart-wait-seconds must exceed the old 120-second detached grace")
    output = arguments.output
    if output is None:
        output = Path(tempfile.mkdtemp(prefix="macscope-installed-shell-restart.")) / "resume.json"
    if not output.is_absolute():
        fail("--output must be an absolute path when supplied")
    output.parent.mkdir(parents=True, exist_ok=True)
    prepare_output = output.with_name(f"{output.stem}.prepare.json")
    rendezvous = output.with_name(f"{output.stem}.rendezvous.json")
    stop_sentinel = output.with_name(f"{output.stem}.stop")
    log_output = output.with_name(f"{output.stem}.unified-log.json")
    for stale in (output, prepare_output, rendezvous, stop_sentinel, log_output):
        if stale.exists():
            fail(f"refusing to overwrite existing restart artifact: {stale}")

    started = datetime.now(timezone.utc)
    environment = os.environ.copy()
    environment[REPORT_ENV] = str(prepare_output)
    environment[MARKER_ENV] = arguments.marker
    environment[TIMEOUT_ENV] = str(max(1.0, min(arguments.timeout_seconds, 30.0)))
    environment[MODE_ENV] = "PREPARE"
    environment[RENDERER_MODE_ENV] = DEFAULT_FULL_SURFACE_MODE
    environment[RENDEZVOUS_ENV] = str(rendezvous)
    environment[STOP_SENTINEL_ENV] = str(stop_sentinel)
    prepare_succeeded = False
    resume_clean = False
    captured_pids: set[int] = set()
    prepare = subprocess.Popen(
        [str(executable)], cwd=str(arguments.app.parent), env=environment,
        text=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )
    try:
        captured_pids.add(prepare.pid)
        prepare_start_identity = process_start_identity(prepare.pid)
        if prepare_start_identity is None:
            fail("could not capture PREPARE process start identity")
        prepare_report = wait_for_report(prepare_output, prepare, arguments.timeout_seconds + 5.0)
        validate_restart_report(
            prepare_report,
            executable,
            arguments.marker,
            "PREPARE",
            build_identity,
            DEFAULT_FULL_SURFACE_MODE,
        )
        prepare_succeeded = True
        captured_pids.add(int(prepare_report["launchedProcessIdentifier"]))
        if rendezvous.stat().st_mode & 0o777 != 0o600:
            fail("public rendezvous permissions are not 0600")
        stop_prepare_cooperatively(prepare, stop_sentinel)
        time.sleep(arguments.restart_wait_seconds)

        resume_environment = environment.copy()
        resume_environment[REPORT_ENV] = str(output)
        resume_environment[MODE_ENV] = "RESUME"
        resume_environment[RENDERER_MODE_ENV] = FORCED_LEGACY_GRID_MODE
        result = subprocess.run(
            [str(executable)], cwd=str(arguments.app.parent), env=resume_environment,
            text=True, capture_output=True, timeout=arguments.timeout_seconds + 10.0, check=False,
        )
        if result.returncode != 0:
            fail(
                f"RESUME app exited {result.returncode}; "
                f"stdout={result.stdout[-400:]!r}; stderr={result.stderr[-400:]!r}"
            )
        resume_report = load_report(output)
        validate_restart_report(
            resume_report,
            executable,
            arguments.marker,
            "RESUME",
            build_identity,
            FORCED_LEGACY_GRID_MODE,
        )
        identity_fields = (
            "brokerIncarnationID", "launchedProcessIdentifier",
            "processStartTimeUnixNanoseconds", "executablePath",
            "processGroupIdentifier",
        )
        if any(prepare_report.get(field) != resume_report.get(field) for field in identity_fields):
            fail("PREPARE/RESUME exact process identity changed")
        if resume_report["transcriptCursor"] <= prepare_report["transcriptCursor"]:
            fail("PREPARE/RESUME transcript cursor did not strictly advance")
        if rendezvous.exists():
            fail("RESUME left the public rendezvous behind")
        resume_clean = True
        shell_pid = int(resume_report["launchedProcessIdentifier"])
        observed_shell = process_executable_path(shell_pid)
        if observed_shell is not None and observed_shell.resolve() == Path("/bin/sh").resolve():
            fail("authenticated cleanup left the exact shell process present")
        log_status = "captured"
        try:
            capture_bounded_logs(started, log_output, arguments.marker, captured_pids)
        except SmokeError as error:
            # Unified logging is supplemental diagnosis. Durable identity, authenticated attach,
            # exact cursor, and cleanup proofs remain the acceptance authority.
            log_status = f"diagnostic unavailable: {error}"
        return {
            "accepted": True,
            "app": str(arguments.app),
            "brokerExecutableSHA256": sha256_file(broker),
            **build_identity,
            "prepareReport": str(prepare_output),
            "resumeReport": str(output),
            "reportSHA256": sha256_file(output),
            "unifiedLog": str(log_output),
            "unifiedLogClassification": "diagnostic",
            "unifiedLogStatus": log_status,
            "waitedSeconds": arguments.restart_wait_seconds,
        }
    finally:
        cleanup_failure: Exception | None = None
        try:
            # Stop and reap PREPARE first. This closes the race where an early harness failure
            # observes no rendezvous while PREPARE is still committing one.
            if prepare.poll() is None:
                stop_prepare_cooperatively(prepare, stop_sentinel)
        except Exception as error:
            cleanup_failure = error
        try:
            if not resume_clean and secure_rendezvous_exists(rendezvous):
                cleanup_output = output.with_name(f"{output.stem}.cleanup.json")
                cleanup_environment = environment.copy()
                cleanup_environment[REPORT_ENV] = str(cleanup_output)
                cleanup_environment[MODE_ENV] = "CLEANUP"
                cleanup_environment[RENDERER_MODE_ENV] = FORCED_LEGACY_GRID_MODE
                cleanup = subprocess.run(
                    [str(executable)], cwd=str(arguments.app.parent), env=cleanup_environment,
                    text=True, capture_output=True, timeout=arguments.timeout_seconds + 10.0, check=False,
                )
                if cleanup.returncode != 0:
                    fail(
                        f"CLEANUP app exited {cleanup.returncode}; "
                        f"stdout={cleanup.stdout[-400:]!r}; stderr={cleanup.stderr[-400:]!r}"
                    )
                cleanup_report = load_report(cleanup_output)
                validate_restart_report(
                    cleanup_report,
                    executable,
                    arguments.marker,
                    "CLEANUP",
                    build_identity,
                    FORCED_LEGACY_GRID_MODE,
                )
                if rendezvous.exists():
                    fail("CLEANUP left the public rendezvous behind")
        except Exception as error:  # Preserve the first cleanup diagnostic.
            if cleanup_failure is None:
                cleanup_failure = error
        if cleanup_failure is not None:
            raise cleanup_failure


def main(arguments: list[str] | None = None) -> int:
    try:
        parsed = parse_arguments(sys.argv[1:] if arguments is None else arguments)
        result = run_smoke(parsed) if parsed.single_launch else run_restart_smoke(parsed)
        print(json.dumps(result, sort_keys=True))
        return 0
    except (SmokeError, subprocess.TimeoutExpired) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
