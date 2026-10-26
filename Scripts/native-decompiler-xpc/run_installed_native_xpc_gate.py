#!/usr/bin/python3 -B
"""Qualify the installed ordinary-Release native XPC product path."""

from __future__ import annotations

import sys

# The command compiler executes this file directly.  Keep repository imports
# bytecode-free even if an embedding host ignores the shebang's ``-B`` flag.
sys.dont_write_bytecode = True

import argparse
import ctypes
from dataclasses import dataclass
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import stat
import subprocess
import time
from typing import Callable


ROOT = Path(__file__).resolve().parents[2]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from Scripts.reconstruction import native_live_preparation_receipt as preparation  # noqa: E402
from Scripts.reconstruction import write_execution_report as execution_report  # noqa: E402


PRODUCTION_APP = Path("/Applications/MacScope.app")
REPORT_NAME = "NativeDecompilerLiveXPC.execution-report.json"
SERVICE_IDENTIFIER = "org.macscope.app.NativeDecompiler"
TEAM_IDENTIFIER = "TEAM000000"
MIN_PHASE_TIMEOUT_SECONDS = 15
MAX_PHASE_TIMEOUT_SECONDS = 120
PROC_ALL_PIDS = 1
PROC_PIDTBSDINFO = 3
PROC_PIDPATHINFO_MAXSIZE = 4 * 1024
MAX_PID_BUFFER_BYTES = 1024 * 1024
MAXCOMLEN = 16


class InstalledNativeGateError(RuntimeError):
    """The installed product did not produce favorable native-XPC evidence."""


@dataclass(frozen=True, order=True)
class ProcessIdentity:
    pid: int
    start_seconds: int
    start_microseconds: int
    uid: int
    executable_path: str


@dataclass(frozen=True)
class ProductProbe:
    app: ProcessIdentity
    service: ProcessIdentity | None
    status: str


class _ProcBSDInfo(ctypes.Structure):
    _fields_ = [
        ("pbi_flags", ctypes.c_uint32),
        ("pbi_status", ctypes.c_uint32),
        ("pbi_xstatus", ctypes.c_uint32),
        ("pbi_pid", ctypes.c_uint32),
        ("pbi_ppid", ctypes.c_uint32),
        ("pbi_uid", ctypes.c_uint32),
        ("pbi_gid", ctypes.c_uint32),
        ("pbi_ruid", ctypes.c_uint32),
        ("pbi_rgid", ctypes.c_uint32),
        ("pbi_svuid", ctypes.c_uint32),
        ("pbi_svgid", ctypes.c_uint32),
        ("rfu_1", ctypes.c_uint32),
        ("pbi_comm", ctypes.c_char * MAXCOMLEN),
        ("pbi_name", ctypes.c_char * (2 * MAXCOMLEN)),
        ("pbi_nfiles", ctypes.c_uint32),
        ("pbi_pgid", ctypes.c_uint32),
        ("pbi_pjobc", ctypes.c_uint32),
        ("e_tdev", ctypes.c_uint32),
        ("e_tpgid", ctypes.c_uint32),
        ("pbi_nice", ctypes.c_int32),
        ("pbi_start_tvsec", ctypes.c_uint64),
        ("pbi_start_tvusec", ctypes.c_uint64),
    ]


AX_OPEN_BINARY = r'''
on run argv
    set targetPID to (item 1 of argv) as integer
    set binaryPath to item 2 of argv
    set timeoutSeconds to (item 3 of argv) as integer
    set deadline to (current date) + timeoutSeconds
    tell application "System Events"
        set matches to every application process whose unix id is targetPID
        if (count of matches) is not 1 then error "exact MacScope process is unavailable"
        set targetProcess to item 1 of matches
        set frontmost of targetProcess to true
        delay 0.25
        keystroke "o" using command down
        repeat
            if (current date) > deadline then error "Open Binary panel timed out"
            try
                if exists sheet 1 of window 1 of targetProcess then exit repeat
            end try
            delay 0.1
        end repeat
        keystroke "g" using {command down, shift down}
        delay 0.25
        keystroke binaryPath
        key code 36
        delay 0.5
        key code 36
        repeat
            if (current date) > deadline then error "Open Binary import timed out"
            try
                if not (exists sheet 1 of window 1 of targetProcess) then exit repeat
            end try
            delay 0.1
        end repeat
        keystroke "2" using command down
    end tell
    return "OPENED"
end run
'''


AX_OBSERVE = r'''
function attributeValue(element, name) {
    try { return element.attributes.byName(name).value(); } catch (_) { return null; }
}
function children(element) {
    try { return element.uiElements(); } catch (_) { return []; }
}
function findIdentifier(root, identifier) {
    var queue = children(root);
    var visited = 0;
    while (queue.length > 0 && visited < 8192) {
        var element = queue.shift();
        visited += 1;
        if (attributeValue(element, "AXIdentifier") === identifier) return element;
        if (visited < 8192) queue = queue.concat(children(element));
    }
    return null;
}
function processForPID(events, pid) {
    var matches = events.applicationProcesses.whose({unixId: pid})();
    if (matches.length !== 1) throw new Error("exact MacScope process is unavailable");
    return matches[0];
}
function pressRequest(process, events) {
    try {
        var menuBar = process.menuBars[0];
        var item = menuBar.menuBarItems.byName("Function");
        item.click();
        delay(0.15);
        var command = item.menus[0].menuItems.byName("Request Native Pseudocode");
        if (command.enabled()) {
            command.click();
            return true;
        }
        events.keyCode(53);
    } catch (_) {}
    return false;
}
function run(argv) {
    var pid = Number(argv[0]);
    var mode = argv[1];
    var timeout = Number(argv[2]);
    var events = Application("System Events");
    var process = processForPID(events, pid);
    var deadline = Date.now() + timeout * 1000;
    var requested = false;
    var nextRequestAt = Date.now() + 1000;
    while (Date.now() < deadline) {
        process = processForPID(events, pid);
        var statusElement = findIdentifier(process, "native.status.value");
        var documentElement = findIdentifier(process, "native.document");
        var status = statusElement === null ? null : attributeValue(statusElement, "AXValue");
        if (typeof status === "string") {
            if (mode === "native" && status.indexOf("Ready") === 0 && documentElement !== null) {
                return JSON.stringify({status: status, document: true});
            }
            if (mode === "fallback" && status.indexOf("MacScope fallback:") >= 0) {
                return JSON.stringify({status: status, document: documentElement !== null});
            }
            if (mode === "native" && !requested && status.indexOf("Pending") === 0
                    && Date.now() >= nextRequestAt) {
                requested = pressRequest(process, events);
                nextRequestAt = Date.now() + 1000;
            }
        }
        delay(0.2);
    }
    throw new Error("native accessibility oracle timed out");
}
'''


def _run(
    argv: list[str],
    *,
    timeout: float,
    environment: dict[str, str] | None = None,
) -> subprocess.CompletedProcess[str]:
    try:
        result = subprocess.run(
            argv,
            check=False,
            capture_output=True,
            text=True,
            timeout=timeout,
            env=environment,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        raise InstalledNativeGateError(f"command could not complete: {argv[0]}: {error}") from error
    if result.returncode != 0:
        diagnostic = (result.stderr or result.stdout).strip()
        raise InstalledNativeGateError(
            f"command failed ({result.returncode}): {argv[0]}: {diagnostic[:4096]}"
        )
    return result


def _validate_runner_file() -> None:
    path = Path(__file__)
    try:
        metadata = path.lstat()
        resolved = path.resolve(strict=True)
        resolved_metadata = resolved.lstat()
    except OSError as error:
        raise InstalledNativeGateError(f"runner identity is unavailable: {error}") from error
    if (
        not stat.S_ISREG(metadata.st_mode)
        or stat.S_ISLNK(metadata.st_mode)
        or metadata.st_nlink != 1
        or not metadata.st_mode & stat.S_IXUSR
        or (metadata.st_dev, metadata.st_ino)
        != (resolved_metadata.st_dev, resolved_metadata.st_ino)
    ):
        raise InstalledNativeGateError(
            "runner must be a canonical, singly linked executable regular file"
        )


def _canonical_directory(path: Path, *, label: str) -> Path:
    if not path.is_absolute():
        raise InstalledNativeGateError(f"{label} must be absolute")
    try:
        metadata = path.lstat()
        resolved = path.resolve(strict=True)
    except OSError as error:
        raise InstalledNativeGateError(f"{label} is unavailable: {error}") from error
    if (
        resolved != path
        or not stat.S_ISDIR(metadata.st_mode)
        or stat.S_ISLNK(metadata.st_mode)
    ):
        raise InstalledNativeGateError(
            f"{label} must be a canonical non-symlink directory"
        )
    return resolved


def _report_path(artifact_root: Path) -> Path:
    root = _canonical_directory(artifact_root, label="artifact root")
    report = root / REPORT_NAME
    if report.exists() or report.is_symlink():
        raise InstalledNativeGateError(
            "canonical native execution report must be absent before product launch"
        )
    return report


def _libproc() -> ctypes.CDLL:
    if sys.platform != "darwin":
        raise InstalledNativeGateError("installed native-XPC gate requires macOS")
    try:
        library = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
    except OSError as error:
        raise InstalledNativeGateError(f"libproc is unavailable: {error}") from error
    library.proc_listpids.argtypes = (
        ctypes.c_uint32,
        ctypes.c_uint32,
        ctypes.c_void_p,
        ctypes.c_int,
    )
    library.proc_listpids.restype = ctypes.c_int
    library.proc_pidpath.argtypes = (ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32)
    library.proc_pidpath.restype = ctypes.c_int
    library.proc_pidinfo.argtypes = (
        ctypes.c_int,
        ctypes.c_int,
        ctypes.c_uint64,
        ctypes.c_void_p,
        ctypes.c_int,
    )
    library.proc_pidinfo.restype = ctypes.c_int
    return library


def _observe_process(library: ctypes.CDLL, pid: int) -> ProcessIdentity | None:
    if pid <= 1:
        return None
    info = _ProcBSDInfo()
    returned = library.proc_pidinfo(
        pid,
        PROC_PIDTBSDINFO,
        0,
        ctypes.byref(info),
        ctypes.sizeof(info),
    )
    if returned != ctypes.sizeof(info) or info.pbi_pid != pid:
        return None
    path_buffer = ctypes.create_string_buffer(PROC_PIDPATHINFO_MAXSIZE)
    path_length = library.proc_pidpath(pid, path_buffer, len(path_buffer))
    if path_length <= 0 or path_length >= len(path_buffer):
        return None
    try:
        executable_path = path_buffer.raw[:path_length].decode("utf-8")
    except UnicodeDecodeError:
        return None
    return ProcessIdentity(
        pid=pid,
        start_seconds=int(info.pbi_start_tvsec),
        start_microseconds=int(info.pbi_start_tvusec),
        uid=int(info.pbi_uid),
        executable_path=executable_path,
    )


def matching_processes(expected_executable: Path) -> tuple[ProcessIdentity, ...]:
    library = _libproc()
    required_bytes = library.proc_listpids(PROC_ALL_PIDS, 0, None, 0)
    if required_bytes <= 0 or required_bytes > MAX_PID_BUFFER_BYTES:
        raise InstalledNativeGateError("libproc returned an invalid PID catalog size")
    capacity_bytes = min(MAX_PID_BUFFER_BYTES, required_bytes + 16 * 1024)
    count = capacity_bytes // ctypes.sizeof(ctypes.c_int)
    buffer = (ctypes.c_int * count)()
    returned_bytes = library.proc_listpids(
        PROC_ALL_PIDS,
        0,
        ctypes.byref(buffer),
        capacity_bytes,
    )
    if returned_bytes <= 0 or returned_bytes >= capacity_bytes:
        raise InstalledNativeGateError("libproc could not enumerate a bounded PID catalog")
    returned_count = returned_bytes // ctypes.sizeof(ctypes.c_int)
    expected = str(expected_executable)
    matches = []
    for pid in sorted(set(int(value) for value in buffer[:returned_count] if value > 1)):
        identity = _observe_process(library, pid)
        if identity is not None and identity.executable_path == expected:
            matches.append(identity)
    return tuple(matches)


def _process_key(identity: ProcessIdentity) -> tuple[int, int, int]:
    return identity.pid, identity.start_seconds, identity.start_microseconds


def _wait_for_one_new_process(
    expected_executable: Path,
    baseline: tuple[ProcessIdentity, ...],
    timeout_seconds: int,
    *,
    provider: Callable[[Path], tuple[ProcessIdentity, ...]] = matching_processes,
) -> ProcessIdentity:
    baseline_keys = {_process_key(identity) for identity in baseline}
    deadline = time.monotonic() + timeout_seconds
    while time.monotonic() < deadline:
        matches = [
            identity
            for identity in provider(expected_executable)
            if _process_key(identity) not in baseline_keys
        ]
        if len(matches) == 1:
            identity = matches[0]
            if identity.uid != os.geteuid() or identity.executable_path != str(expected_executable):
                raise InstalledNativeGateError(
                    "new process identity is not the exact current-user product"
                )
            return identity
        if len(matches) > 1:
            raise InstalledNativeGateError(
                f"expected one new {expected_executable.name} process, found {len(matches)}"
            )
        time.sleep(0.05)
    raise InstalledNativeGateError(f"timed out waiting for {expected_executable.name}")


def _same_live_process(identity: ProcessIdentity) -> bool:
    observed = _observe_process(_libproc(), identity.pid)
    return observed == identity


def _wait_process_exit(identity: ProcessIdentity, timeout_seconds: float) -> bool:
    deadline = time.monotonic() + timeout_seconds
    while time.monotonic() < deadline:
        if not _same_live_process(identity):
            return True
        time.sleep(0.05)
    return not _same_live_process(identity)


def _terminate_owned(identity: ProcessIdentity) -> None:
    if not _same_live_process(identity):
        return
    os.kill(identity.pid, signal.SIGTERM)
    if _wait_process_exit(identity, 5):
        return
    if not _same_live_process(identity):
        return
    os.kill(identity.pid, signal.SIGKILL)
    if not _wait_process_exit(identity, 3):
        raise InstalledNativeGateError(
            f"runner-owned PID {identity.pid} did not terminate"
        )


def _launch_app(
    installed_app: Path,
    application_executable: Path,
    enabled: bool,
    timeout_seconds: int,
) -> tuple[ProcessIdentity, tuple[ProcessIdentity, ...]]:
    baseline = matching_processes(application_executable)
    environment_value = "1" if enabled else "0"
    _run(
        [
            "/usr/bin/open",
            "-n",
            "-F",
            "-a",
            str(installed_app),
            "--env",
            f"MACSCOPE_NATIVE_DECOMPILER_ENABLED={environment_value}",
        ],
        timeout=min(timeout_seconds, 15),
    )
    return (
        _wait_for_one_new_process(
            application_executable,
            baseline,
            timeout_seconds,
        ),
        baseline,
    )


def _open_candidate_binary(
    app: ProcessIdentity,
    application_executable: Path,
    timeout_seconds: int,
) -> None:
    result = _run(
        [
            "/usr/bin/osascript",
            "-e",
            AX_OPEN_BINARY,
            "--",
            str(app.pid),
            str(application_executable),
            str(timeout_seconds),
        ],
        timeout=timeout_seconds + 5,
    )
    if result.stdout.strip() != "OPENED":
        raise InstalledNativeGateError(
            "Open Binary accessibility driver returned unexpected output"
        )


def _observe_accessibility(
    app: ProcessIdentity,
    *,
    mode: str,
    timeout_seconds: int,
) -> tuple[str, bool]:
    result = _run(
        [
            "/usr/bin/osascript",
            "-l",
            "JavaScript",
            "-e",
            AX_OBSERVE,
            "--",
            str(app.pid),
            mode,
            str(timeout_seconds),
        ],
        timeout=timeout_seconds + 5,
    )
    try:
        payload = json.loads(result.stdout)
    except (json.JSONDecodeError, UnicodeError) as error:
        raise InstalledNativeGateError("accessibility oracle returned malformed JSON") from error
    if (
        not isinstance(payload, dict)
        or set(payload) != {"status", "document"}
        or not isinstance(payload["status"], str)
        or not isinstance(payload["document"], bool)
    ):
        raise InstalledNativeGateError("accessibility oracle returned an invalid closed result")
    status = payload["status"]
    if not status or len(status.encode("utf-8")) > 4096:
        raise InstalledNativeGateError("accessibility status is empty or unbounded")
    return status, payload["document"]


def _designated_requirement(service_bundle: Path, timeout_seconds: int) -> str:
    _run(
        [
            "/usr/bin/codesign",
            "--verify",
            "--deep",
            "--strict",
            "--verbose=2",
            str(service_bundle),
        ],
        timeout=timeout_seconds,
    )
    result = _run(
        ["/usr/bin/codesign", "-d", "-r-", str(service_bundle)],
        timeout=timeout_seconds,
    )
    combined = "\n".join((result.stdout, result.stderr))
    matches = re.findall(r"(?m)^\s*designated\s*=>\s*(.+?)\s*$", combined)
    if len(matches) != 1 or SERVICE_IDENTIFIER not in matches[0]:
        raise InstalledNativeGateError(
            "native service designated requirement is unavailable or ambiguous"
        )
    return matches[0]


def _authenticate_service_process(
    identity: ProcessIdentity,
    service_executable: Path,
    service_bundle: Path,
    timeout_seconds: int,
) -> ProcessIdentity:
    library = _libproc()
    before = _observe_process(library, identity.pid)
    if (
        before != identity
        or identity.uid != os.geteuid()
        or identity.executable_path != str(service_executable)
    ):
        raise InstalledNativeGateError(
            "native service process identity changed before authentication"
        )
    requirement = _designated_requirement(service_bundle, timeout_seconds)
    _run(
        [
            "/usr/bin/codesign",
            "--verify",
            "--strict",
            "--verbose=2",
            f"-R={requirement}",
            f"+{identity.pid}",
        ],
        timeout=timeout_seconds,
    )
    details = _run(
        ["/usr/bin/codesign", "-dvvv", f"+{identity.pid}"],
        timeout=timeout_seconds,
    )
    detail_text = "\n".join((details.stdout, details.stderr))
    if (
        f"Identifier={SERVICE_IDENTIFIER}" not in detail_text
        or f"TeamIdentifier={TEAM_IDENTIFIER}" not in detail_text
        or re.search(r"(?m)^CodeDirectory .*\bruntime\b", detail_text) is None
    ):
        raise InstalledNativeGateError("dynamic native service signing identity is not exact")
    after = _observe_process(library, identity.pid)
    if after != before:
        raise InstalledNativeGateError("native service process changed during authentication")
    return after


def _native_probe(
    authority: preparation.InstalledReleaseAuthority,
    installed_app: Path,
    timeout_seconds: int,
) -> ProductProbe:
    service_baseline = matching_processes(authority.native_executable)
    app, _ = _launch_app(
        installed_app,
        authority.application_executable,
        True,
        timeout_seconds,
    )
    try:
        _open_candidate_binary(app, authority.application_executable, timeout_seconds)
        status, document = _observe_accessibility(
            app,
            mode="native",
            timeout_seconds=timeout_seconds,
        )
        if (
            not document
            or not status.startswith("Ready, ")
            or ", engine " not in status
            or "MacScope fallback:" in status
            or "Failure:" in status
            or any(status.startswith(prefix) for prefix in ("Unavailable", "Failed", "Stale"))
        ):
            raise InstalledNativeGateError(
                "installed native response did not satisfy the Ready oracle"
            )
        service = _wait_for_one_new_process(
            authority.native_executable,
            service_baseline,
            timeout_seconds,
        )
        service_bundle = authority.native_executable.parents[2]
        service = _authenticate_service_process(
            service,
            authority.native_executable,
            service_bundle,
            timeout_seconds,
        )
        return ProductProbe(app=app, service=service, status=status)
    except BaseException:
        _terminate_owned(app)
        raise


def _fallback_probe(
    authority: preparation.InstalledReleaseAuthority,
    installed_app: Path,
    service_baseline: tuple[ProcessIdentity, ...],
    timeout_seconds: int,
) -> ProductProbe:
    app, _ = _launch_app(
        installed_app,
        authority.application_executable,
        False,
        timeout_seconds,
    )
    try:
        _open_candidate_binary(app, authority.application_executable, timeout_seconds)
        status, document = _observe_accessibility(
            app,
            mode="fallback",
            timeout_seconds=timeout_seconds,
        )
        if document or "MacScope fallback:" not in status or status.startswith("Ready"):
            raise InstalledNativeGateError(
                "disabled policy did not expose fail-closed MacScope fallback"
            )
        observed_service = matching_processes(authority.native_executable)
        if {_process_key(item) for item in observed_service} != {
            _process_key(item) for item in service_baseline
        }:
            raise InstalledNativeGateError(
                "disabled policy created or replaced a native service process"
            )
        return ProductProbe(app=app, service=None, status=status)
    except BaseException:
        _terminate_owned(app)
        raise


def _report_document(
    arguments: argparse.Namespace,
    started: int,
    ended: int,
) -> dict[str, object]:
    report_arguments = argparse.Namespace(
        qualification_run_id=arguments.qualification_run_id,
        qualification_run_nonce=arguments.qualification_run_nonce,
        started_at_unix_ms=started,
        ended_at_unix_ms=ended,
        result="passed",
        exit_code=0,
    )
    authority = execution_report.qualification_run_authority(report_arguments)
    return execution_report.document(
        report_arguments,
        qualification_run=authority,
        predecessor_observations_sha256=arguments.predecessor_observations_sha256,
    )


def run_gate(arguments: argparse.Namespace) -> tuple[ProductProbe, ProductProbe, Path]:
    _validate_runner_file()
    if not (
        MIN_PHASE_TIMEOUT_SECONDS
        <= arguments.phase_timeout_seconds
        <= MAX_PHASE_TIMEOUT_SECONDS
    ):
        raise InstalledNativeGateError(
            "phase timeout must be "
            f"{MIN_PHASE_TIMEOUT_SECONDS}...{MAX_PHASE_TIMEOUT_SECONDS} seconds"
        )
    report_path = _report_path(arguments.artifact_root)
    authority = preparation.validate_installed_release(
        arguments.preparation_receipt,
        arguments.candidate_identity,
        arguments.installed_app,
    )
    started = time.time_ns() // 1_000_000
    initial_service_baseline = matching_processes(authority.native_executable)
    native: ProductProbe | None = None
    fallback: ProductProbe | None = None
    publication: execution_report.PublishedFile | None = None
    try:
        native = _native_probe(
            authority,
            arguments.installed_app,
            arguments.phase_timeout_seconds,
        )
        _terminate_owned(native.app)
        if native.service is None:
            raise InstalledNativeGateError(
                "native response lacks an authenticated service process"
            )
        if not _wait_process_exit(native.service, min(arguments.phase_timeout_seconds, 10)):
            raise InstalledNativeGateError("runner-owned native service outlived its exact client")
        if {_process_key(item) for item in matching_processes(authority.native_executable)} != {
            _process_key(item) for item in initial_service_baseline
        }:
            raise InstalledNativeGateError(
                "native service baseline was not restored before fallback proof"
            )

        fallback = _fallback_probe(
            authority,
            arguments.installed_app,
            initial_service_baseline,
            arguments.phase_timeout_seconds,
        )
        _terminate_owned(fallback.app)
        preparation.require_unchanged_installed_release(
            authority,
            phase="installed native-XPC report publication",
        )
        ended = time.time_ns() // 1_000_000
        publication = execution_report.write_create_only(
            report_path,
            _report_document(arguments, started, ended),
        )
        preparation.require_unchanged_installed_release(
            authority,
            phase="installed native-XPC report post-publication fence",
        )
    except BaseException:
        if fallback is not None:
            _terminate_owned(fallback.app)
        if native is not None:
            _terminate_owned(native.app)
            if native.service is not None and _same_live_process(native.service):
                _terminate_owned(native.service)
        if publication is not None:
            execution_report.remove_published_file(publication)
        raise
    if native is None or fallback is None:
        raise InstalledNativeGateError("installed native-XPC proof did not complete")
    return native, fallback, report_path


def parse_arguments(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--installed-app", type=Path, required=True)
    parser.add_argument("--candidate-identity", type=Path, required=True)
    parser.add_argument("--preparation-receipt", type=Path, required=True)
    parser.add_argument("--artifact-root", type=Path, required=True)
    parser.add_argument("--qualification-run-id", required=True)
    parser.add_argument("--qualification-run-nonce", required=True)
    parser.add_argument("--predecessor-observations-sha256", required=True)
    parser.add_argument("--phase-timeout-seconds", type=int, required=True)
    return parser.parse_args(argv)


def main(argv: list[str] | None = None, *, _allow_test_app: bool = False) -> int:
    arguments = parse_arguments(argv)
    if not _allow_test_app and arguments.installed_app != PRODUCTION_APP:
        print(
            f"ERROR: installed native-XPC gate requires {PRODUCTION_APP}",
            file=sys.stderr,
        )
        return 1
    try:
        native, fallback, report_path = run_gate(arguments)
    except (
        OSError,
        ValueError,
        preparation.PreparationReceiptError,
        execution_report.ExecutionReportError,
        InstalledNativeGateError,
    ) as error:
        print(f"ERROR: installed native-XPC gate failed: {error}", file=sys.stderr)
        return 1
    assert native.service is not None
    print(f"MACSCOPE_INSTALLED_NATIVE_APP={arguments.installed_app}")
    print(f"MACSCOPE_SIGNED_NATIVE_EXECUTABLE={native.service.executable_path}")
    print(f"MACSCOPE_INSTALLED_NATIVE_APP_PID={native.app.pid}")
    print(f"MACSCOPE_INSTALLED_NATIVE_SERVICE_PID={native.service.pid}")
    print(
        "MACSCOPE_INSTALLED_NATIVE_RESPONSE_STATUS_SHA256="
        + hashlib.sha256(native.status.encode("utf-8")).hexdigest()
    )
    print(
        "MACSCOPE_INSTALLED_NATIVE_FALLBACK_STATUS_SHA256="
        + hashlib.sha256(fallback.status.encode("utf-8")).hexdigest()
    )
    print(f"MACSCOPE_SIGNED_NATIVE_EXECUTION_REPORT={report_path}")
    print("PASS: installed native XPC gate")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
