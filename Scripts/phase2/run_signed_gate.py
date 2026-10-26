#!/usr/bin/env python3
"""Launch the exact signed Phase 2 F4C Gate candidate once, without injection.

Authority proof is the default mode. Live mode is explicit and has no retry path;
the Gate's durable one-shot claim remains the authoritative replay protection.
"""

from __future__ import annotations

import argparse
import ctypes
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time
from typing import Any, BinaryIO, NoReturn
import uuid


AUTHORITY_ARGUMENT = "--phase2-f4c-gate-authority-proof"
CANARY_ARGUMENT = "--phase2-f4c-installed-canary"
LIVE_ARGUMENT = "--phase2-f4c-signed-live-gate"
HISTORICAL_PROFILE = "historical-f4c"
CANDIDATE_PROFILE = "qwen38-v2-q6k"
PROFILE_ARGUMENT = "--phase2-f4c-profile="
PROFILE_KEYS = {"profile_selector", "qualification_definition_sha256", "admission_state"}
PROVIDER_KEYS = {"provider_build_sha256", "runtime_closure_sha256", "template_authority_sha256"}
SOURCE_KEYS = {"app_executable_sha256", "worker_executable_sha256", "git_head_commit"}
CANARY_OPT_IN_KEY = "MACSCOPE_RUN_PHASE2_F4C_INSTALLED_CANARY"
LIVE_OPT_IN_KEY = "MACSCOPE_RUN_PHASE2_F4C_SIGNED_GATE"
EXPECTED_STATUS = {
    "authority": "authority-verified",
    "canary": "canary-completed",
    "live": "completed",
}
DEFAULT_TIMEOUT_SECONDS = {
    "authority": 300.0,
    "canary": 300.0,
    "live": 21_600.0,
}
MAXIMUM_TIMEOUT_SECONDS = 21_600.0
MAXIMUM_CANARY_TIMEOUT_SECONDS = 300.0
PROCESS_CLEANUP_GRACE_SECONDS = 5.0
PROC_PIDPATHINFO_MAXSIZE = 4096
CANARY_TERMINAL_KEYS = frozenset(
    {
        "app_executable_sha256",
        "canary_evidence_sha256",
        "evidence_location",
        "git_head_commit",
        "run_id",
        "schema_version",
        "status",
        "worker_executable_sha256",
    }
)


class LaunchError(RuntimeError):
    pass


def parse_arguments(arguments: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Run one exact signed MacScope F4C Gate process.", allow_abbrev=False
    )
    if sum(value == "--profile" or value.startswith("--profile=") for value in arguments) > 1:
        parser.error("--profile must be supplied at most once")
    parser.add_argument("--profile", choices=(HISTORICAL_PROFILE, CANDIDATE_PROFILE),
                        default=HISTORICAL_PROFILE)
    parser.add_argument(
        "--mode",
        choices=("authority", "canary", "live"),
        default="authority",
        help=(
            "authority is non-live and is the default; canary runs only the "
            "installed real-provider canary; live runs the complete one-shot Gate"
        ),
    )
    parser.add_argument("--candidate-app", required=True, type=Path)
    parser.add_argument("--stdout-log", required=True, type=Path)
    parser.add_argument("--stderr-log", required=True, type=Path)
    parser.add_argument("--timeout-seconds", type=float)
    return parser.parse_args(arguments)


def fail(message: str) -> NoReturn:
    raise LaunchError(message)


def validate_paths(
    candidate_app: Path,
    stdout_log: Path,
    stderr_log: Path,
) -> Path:
    if not candidate_app.is_absolute():
        fail("candidate app path must be absolute")
    if (
        candidate_app.suffix != ".app"
        or candidate_app.is_symlink()
        or not candidate_app.is_dir()
    ):
        fail("candidate app must be an existing .app directory")

    executable = candidate_app / "Contents" / "MacOS" / "MacScope"
    if executable.is_symlink() or not executable.is_file():
        fail("candidate executable must be an existing non-symlink regular file")
    if not os.access(executable, os.X_OK):
        fail("candidate executable is not executable")

    if not stdout_log.is_absolute() or not stderr_log.is_absolute():
        fail("evidence log paths must be absolute")
    if stdout_log.resolve(strict=False) == stderr_log.resolve(strict=False):
        fail("stdout and stderr evidence logs must be distinct")
    for log in (stdout_log, stderr_log):
        if not log.parent.is_dir():
            fail(f"evidence log parent does not exist: {log.parent}")
        if log.exists() or log.is_symlink():
            fail(f"refusing to overwrite evidence log: {log}")
    return executable


def minimal_environment(mode: str) -> dict[str, str]:
    required = ("HOME", "TMPDIR", "USER")
    missing = [key for key in required if not os.environ.get(key)]
    if missing:
        fail("required launch environment is missing: " + ", ".join(missing))
    environment = {
        "HOME": os.environ["HOME"],
        "PATH": "/usr/bin:/bin",
        "TMPDIR": os.environ["TMPDIR"],
        "USER": os.environ["USER"],
    }
    if mode == "canary":
        environment[CANARY_OPT_IN_KEY] = "1"
    elif mode == "live":
        environment[LIVE_OPT_IN_KEY] = "1"
    return environment


def timeout_for(mode: str, requested: float | None) -> float:
    timeout = DEFAULT_TIMEOUT_SECONDS[mode] if requested is None else requested
    maximum = (
        MAXIMUM_CANARY_TIMEOUT_SECONDS
        if mode == "canary"
        else MAXIMUM_TIMEOUT_SECONDS
    )
    if not 0 < timeout <= maximum:
        fail(
            f"timeout must be greater than zero and no more than "
            f"{maximum:g} seconds"
        )
    return timeout


def canonical_executable_for_pid(pid: int) -> Path | None:
    """Return the running PID's canonical executable, or None after exit."""
    libproc = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
    proc_pidpath = libproc.proc_pidpath
    proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
    proc_pidpath.restype = ctypes.c_int
    buffer = ctypes.create_string_buffer(PROC_PIDPATHINFO_MAXSIZE)
    if proc_pidpath(pid, buffer, len(buffer)) <= 0:
        return None
    try:
        return Path(os.fsdecode(buffer.value)).resolve(strict=True)
    except (OSError, RuntimeError):
        return None


def all_process_ids() -> list[int]:
    libproc = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
    proc_listallpids = libproc.proc_listallpids
    proc_listallpids.argtypes = [ctypes.c_void_p, ctypes.c_int]
    proc_listallpids.restype = ctypes.c_int
    capacity = max(proc_listallpids(None, 0) + 64, 64)
    while True:
        buffer = (ctypes.c_int * capacity)()
        count = proc_listallpids(buffer, ctypes.sizeof(buffer))
        if count < 0:
            fail("could not enumerate processes during candidate cleanup")
        if count < capacity:
            return [pid for pid in buffer[:count] if pid > 0]
        capacity *= 2


def pid_matches_executable(pid: int, expected_executable: Path) -> bool:
    return canonical_executable_for_pid(pid) == expected_executable


def signal_if_owned(pid: int, expected_executable: Path, signal_number: int) -> bool:
    """Signal only after an immediate exact executable-path ownership check."""
    if not pid_matches_executable(pid, expected_executable):
        return False
    try:
        os.kill(pid, signal_number)
    except ProcessLookupError:
        return False
    return True


def pids_for_exact_executable(expected_executable: Path) -> list[int]:
    return sorted(
        pid
        for pid in all_process_ids()
        if pid_matches_executable(pid, expected_executable)
    )


def wait_until_no_exact_executable(
    expected_executable: Path,
    timeout_seconds: float,
) -> list[int]:
    deadline = time.monotonic() + timeout_seconds
    while True:
        remaining = pids_for_exact_executable(expected_executable)
        if not remaining or time.monotonic() >= deadline:
            return remaining
        time.sleep(0.05)


def confirm_candidate_workers_gone(
    worker_executable: Path,
    grace_seconds: float = PROCESS_CLEANUP_GRACE_SECONDS,
) -> None:
    """Observe candidate workers boundedly without signaling an unbound PID."""
    remaining = wait_until_no_exact_executable(worker_executable, grace_seconds)
    if remaining:
        fail(
            "candidate AI worker remained after recorded app PID cleanup; "
            "refusing to signal unbound exact-path PID(s): "
            + ", ".join(str(pid) for pid in remaining)
        )


def terminate_and_reap_candidate(
    process: subprocess.Popen[bytes],
    expected_executable: Path,
    grace_seconds: float = PROCESS_CLEANUP_GRACE_SECONDS,
) -> None:
    if process.poll() is not None:
        return
    if not signal_if_owned(process.pid, expected_executable, signal.SIGTERM):
        try:
            process.wait(timeout=0.1)
            return
        except subprocess.TimeoutExpired:
            fail(
                f"refusing to terminate candidate PID {process.pid}: "
                "its executable no longer matches the exact candidate"
            )
    try:
        process.wait(timeout=grace_seconds)
        return
    except subprocess.TimeoutExpired:
        pass
    if not signal_if_owned(process.pid, expected_executable, signal.SIGKILL):
        try:
            process.wait(timeout=0.1)
            return
        except subprocess.TimeoutExpired:
            fail(
                f"refusing to kill candidate PID {process.pid}: "
                "its executable no longer matches the exact candidate"
            )
    process.wait()


def reserve_logs(
    stdout_log: Path,
    stderr_log: Path,
) -> tuple[BinaryIO, BinaryIO]:
    stdout_handle: BinaryIO | None = None
    try:
        stdout_handle = stdout_log.open("x+b")
        os.chmod(stdout_log, 0o600)
        stderr_handle = stderr_log.open("x+b")
        os.chmod(stderr_log, 0o600)
    except OSError as error:
        if stdout_handle is not None:
            stdout_handle.close()
        fail(f"could not reserve fresh evidence logs: {error}")
    return stdout_handle, stderr_handle


def read_captured_logs(
    stdout_handle: BinaryIO,
    stderr_handle: BinaryIO,
) -> tuple[bytes, bytes]:
    captured: list[bytes] = []
    for handle in (stdout_handle, stderr_handle):
        handle.flush()
        os.fsync(handle.fileno())
        handle.seek(0)
        captured.append(handle.read())
    return captured[0], captured[1]


def reject_json_constant(value: str) -> NoReturn:
    fail(f"terminal record contains invalid JSON constant: {value}")


def reject_duplicate_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            fail(f"terminal record contains duplicate key: {key}")
        result[key] = value
    return result


def is_lowercase_hex(value: Any, length: int) -> bool:
    return (
        isinstance(value, str)
        and len(value) == length
        and all(character in "0123456789abcdef" for character in value)
    )


def validate_canary_terminal_record(record: dict[str, Any]) -> None:
    if set(record) != CANARY_TERMINAL_KEYS:
        fail("candidate canary terminal record has unexpected fields")
    run_id = record.get("run_id")
    try:
        canonical_run_id = str(uuid.UUID(run_id)) if isinstance(run_id, str) else None
    except (ValueError, AttributeError):
        canonical_run_id = None
    if canonical_run_id != run_id:
        fail("candidate canary terminal record has invalid run_id")
    if not is_lowercase_hex(record.get("git_head_commit"), 40):
        fail("candidate canary terminal record has invalid git_head_commit")
    for key in (
        "app_executable_sha256",
        "canary_evidence_sha256",
        "worker_executable_sha256",
    ):
        if not is_lowercase_hex(record.get(key), 64):
            fail(f"candidate canary terminal record has invalid {key}")
    expected_location = f"MacScope/Qualification/F4C/{run_id}/canary.json"
    if record.get("evidence_location") != expected_location:
        fail("candidate canary terminal record has invalid evidence_location")


def validate_profile_terminal_record(record: dict[str, Any], mode: str) -> None:
    base = {
        "authority": SOURCE_KEYS | {"schema_version", "status"},
        "canary": set(CANARY_TERMINAL_KEYS),
        "live": SOURCE_KEYS | {"artifact_location", "report_id", "run_id", "schema_version", "status", "verdict"},
    }[mode]
    expected_keys = base | PROFILE_KEYS | (PROVIDER_KEYS if mode != "authority" else set())
    if set(record) != expected_keys:
        fail("candidate profile terminal record has unexpected fields")
    if record.get("profile_selector") != CANDIDATE_PROFILE:
        fail("candidate profile terminal selector mismatch")
    for key in {"qualification_definition_sha256", "app_executable_sha256", "worker_executable_sha256"} | (PROVIDER_KEYS if mode != "authority" else set()):
        if not is_lowercase_hex(record.get(key), 64):
            fail(f"candidate profile terminal record has invalid {key}")
    if not is_lowercase_hex(record.get("git_head_commit"), 40):
        fail("candidate profile terminal record has invalid git_head_commit")
    expected_state = {"authority": "unqualified", "canary": "canary-passed", "live": "qualified" if record.get("verdict") == "certified" else "failed"}[mode]
    if record.get("admission_state") != expected_state:
        fail("candidate profile admission state mismatch")
    if mode == "canary":
        validate_canary_terminal_record({key: record[key] for key in CANARY_TERMINAL_KEYS})
    elif mode == "live":
        if record.get("verdict") not in ("certified", "compatible", "experimental", "unsupported", "inconclusive"):
            fail("candidate profile verdict is invalid")
        report_id = record.get("report_id")
        if not isinstance(report_id, str) or not report_id.startswith("sha256:") or not is_lowercase_hex(report_id[7:], 64):
            fail("candidate profile report identity is invalid")
        if record.get("artifact_location") != f"MacScope/Qualification/F4C/reports/{report_id[7:]}/report.json":
            fail("candidate profile report location is invalid")
        try:
            valid_run = str(uuid.UUID(record.get("run_id"))) == record.get("run_id")
        except (ValueError, TypeError, AttributeError):
            valid_run = False
        if not valid_run:
            fail("candidate profile run identity is invalid")


def validate_terminal_record(stdout: bytes, stderr: bytes, mode: str,
                             profile: str = HISTORICAL_PROFILE,
                             expected_source: dict[str, str] | None = None) -> bytes:
    if profile not in (HISTORICAL_PROFILE, CANDIDATE_PROFILE):
        fail("unknown qualification profile")
    if stderr:
        fail("candidate emitted unexpected stderr")
    if not stdout.endswith(b"\n") or stdout.count(b"\n") != 1:
        fail("candidate stdout must contain exactly one newline-terminated JSON line")
    line = stdout[:-1]
    if not line or b"\r" in line:
        fail("candidate stdout is not one canonical JSON line")
    try:
        text = line.decode("utf-8", errors="strict")
        record = json.loads(
            text,
            object_pairs_hook=reject_duplicate_keys,
            parse_constant=reject_json_constant,
        )
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        fail(f"candidate stdout is not valid UTF-8 JSON: {error}")
    if not isinstance(record, dict):
        fail("candidate terminal record must be a JSON object")

    canonical = json.dumps(
        record,
        ensure_ascii=False,
        allow_nan=False,
        separators=(",", ":"),
        sort_keys=True,
    ).encode("utf-8")
    if canonical != line:
        fail("candidate terminal record is not canonical JSON")
    if type(record.get("schema_version")) is not int or record.get("schema_version") != (1 if profile == HISTORICAL_PROFILE else 2):
        fail("candidate terminal record has unexpected schema_version")
    expected = EXPECTED_STATUS[mode]
    if record.get("status") != expected:
        fail(f"candidate terminal status is not {expected!r}")
    if profile == CANDIDATE_PROFILE:
        validate_profile_terminal_record(record, mode)
        if expected_source is not None and any(record.get(key) != value for key, value in expected_source.items()):
            fail("candidate terminal source app identity mismatch")
    elif mode == "canary":
        validate_canary_terminal_record(record)
    return stdout


def invoke_once(
    executable: Path,
    worker_executable: Path | None,
    mode: str,
    environment: dict[str, str],
    timeout_seconds: float,
    stdout_handle: BinaryIO,
    stderr_handle: BinaryIO,
    profile: str = HISTORICAL_PROFILE,
) -> tuple[int, bool, int]:
    if profile not in (HISTORICAL_PROFILE, CANDIDATE_PROFILE):
        fail("unknown qualification profile")
    gate_argument = {
        "authority": AUTHORITY_ARGUMENT,
        "canary": CANARY_ARGUMENT,
        "live": LIVE_ARGUMENT,
    }[mode]
    process = subprocess.Popen(
        [os.fspath(executable), gate_argument] +
        ([PROFILE_ARGUMENT + profile] if profile != HISTORICAL_PROFILE else []),
        stdin=subprocess.DEVNULL,
        stdout=stdout_handle,
        stderr=stderr_handle,
        env=environment,
        close_fds=True,
    )
    recorded_pid = process.pid
    try:
        process.wait(timeout=timeout_seconds)
    except subprocess.TimeoutExpired:
        cleanup_errors: list[str] = []
        try:
            terminate_and_reap_candidate(process, executable.resolve(strict=True))
        except LaunchError as error:
            cleanup_errors.append(str(error))
        if worker_executable is not None:
            try:
                confirm_candidate_workers_gone(worker_executable)
            except LaunchError as error:
                cleanup_errors.append(str(error))
        if cleanup_errors:
            fail("; ".join(cleanup_errors))
        return process.returncode, True, recorded_pid
    return process.returncode, False, recorded_pid


def main(arguments: list[str]) -> int:
    options = parse_arguments(arguments)
    executable = validate_paths(
        options.candidate_app,
        options.stdout_log,
        options.stderr_log,
    )
    worker_path = (
        options.candidate_app
        / "Contents"
        / "XPCServices"
        / "AIAgentWorkerXPCService.xpc"
        / "Contents"
        / "MacOS"
        / "AIAgentWorkerXPCService"
    )
    worker_executable = (
        worker_path.resolve(strict=True)
        if worker_path.is_file() and not worker_path.is_symlink()
        else None
    )
    environment = minimal_environment(options.mode)
    timeout_seconds = timeout_for(options.mode, options.timeout_seconds)
    expected_source = None
    if options.profile == CANDIDATE_PROFILE:
        if worker_executable is None:
            fail("candidate profile requires its signed worker")
        expected_source = {
            "app_executable_sha256": file_sha256(executable),
            "worker_executable_sha256": file_sha256(worker_executable),
            "git_head_commit": source_commit(options.candidate_app),
        }
        if options.mode != "authority":
            authority_stdout = options.stdout_log.with_name(options.stdout_log.name + ".authority")
            authority_stderr = options.stderr_log.with_name(options.stderr_log.name + ".authority")
            validate_paths(options.candidate_app, authority_stdout, authority_stderr)
            handles = reserve_logs(authority_stdout, authority_stderr)
            try:
                code, timed_out, _ = invoke_once(
                    executable, worker_executable, "authority", minimal_environment("authority"),
                    DEFAULT_TIMEOUT_SECONDS["authority"], *handles, profile=options.profile)
                authority_output, authority_error = read_captured_logs(*handles)
            finally:
                for handle in handles:
                    handle.close()
            if timed_out or code != 0:
                fail("candidate profile authority preflight failed; evidence retained")
            validate_terminal_record(authority_output, authority_error, "authority",
                                     options.profile, expected_source)
            if (file_sha256(executable) != expected_source["app_executable_sha256"] or
                file_sha256(worker_executable) != expected_source["worker_executable_sha256"] or
                source_commit(options.candidate_app) != expected_source["git_head_commit"]):
                fail("candidate changed during authority preflight")
            expected_source["qualification_definition_sha256"] = json.loads(authority_output)[
                "qualification_definition_sha256"]

    stdout_handle, stderr_handle = reserve_logs(options.stdout_log, options.stderr_log)
    try:
        try:
            return_code, timed_out, recorded_pid = invoke_once(
                executable,
                worker_executable,
                options.mode,
                environment,
                timeout_seconds,
                stdout_handle,
                stderr_handle,
                options.profile,
            )
        except OSError as error:
            fail(f"could not launch exact candidate executable: {error}")
        stdout, stderr = read_captured_logs(stdout_handle, stderr_handle)
    finally:
        stdout_handle.close()
        stderr_handle.close()

    if timed_out:
        fail(
            f"candidate PID {recorded_pid} timed out after "
            f"{timeout_seconds:g} seconds and was reaped"
        )
    if return_code != 0:
        fail(f"candidate exited with status {return_code}")
    if expected_source is not None and (
        file_sha256(executable) != expected_source["app_executable_sha256"] or
        file_sha256(worker_executable) != expected_source["worker_executable_sha256"] or
        source_commit(options.candidate_app) != expected_source["git_head_commit"]
    ):
        fail("candidate source executable changed during qualification")
    canonical_record = validate_terminal_record(stdout, stderr, options.mode, options.profile, expected_source)
    sys.stdout.buffer.write(canonical_record)
    sys.stdout.buffer.flush()
    return 0


def file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def source_commit(app: Path) -> str:
    path = app / "Contents" / "Resources" / "MacScopeBuildProvenance.json"
    if path.is_symlink() or not path.is_file() or path.stat().st_size > 1024 * 1024:
        fail("candidate profile requires bounded build provenance")
    try:
        provenance = json.loads(path.read_text(encoding="utf-8"),
                                object_pairs_hook=reject_duplicate_keys,
                                parse_constant=reject_json_constant)
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        fail(f"candidate build provenance is unavailable: {type(error).__name__}")
    if not isinstance(provenance, dict) or not is_lowercase_hex(provenance.get("git_head_commit"), 40):
        fail("candidate build provenance source commit is invalid")
    return provenance["git_head_commit"]


if __name__ == "__main__":
    try:
        raise SystemExit(main(sys.argv[1:]))
    except LaunchError as error:
        print(f"run_signed_gate.py: {error}", file=sys.stderr)
        raise SystemExit(1)
