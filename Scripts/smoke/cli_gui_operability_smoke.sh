#!/bin/bash
# Deterministic, offline CLI/GUI operability smoke for an installed MacScope.app.
# Repository preflight is the default. A final installed run can emit the exact
# closed report accepted by the installed-operability bridge.

set -euo pipefail
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
exec /usr/bin/python3 -B - "$SCRIPT_DIR" "$@" <<'PY'
from __future__ import annotations

import argparse
import contextlib
import hashlib
import json
import os
import re
import selectors
import signal
import stat
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from typing import Any, NoReturn


SCRIPT_DIR = Path(sys.argv.pop(1))
REPOSITORY_ROOT = SCRIPT_DIR.parents[1]
sys.path.insert(0, str(REPOSITORY_ROOT))

from Scripts import ws24_emit_installed_qualification_report as bridge  # noqa: E402
from Scripts.reconstruction_gate_f.canonical_json import (  # noqa: E402
    CanonicalJSONError,
    canonical_bytes,
    decode_canonical_bytes,
)


DEFAULT_APP = Path("/Applications/MacScope.app")
DEFAULT_BINARY = Path("/usr/bin/true")
EXECUTABLE_RELATIVE = Path("Contents/MacOS/MacScope")
PROVENANCE_RELATIVE = Path("Contents/Resources/MacScopeBuildProvenance.json")
MAX_CAPTURE_BYTES = 64 * 1024
MAX_JSON_BYTES = 4 * 1024 * 1024
MAX_DIAGNOSTIC_BYTES = 512
STOP_GRACE_SECONDS = 1.0
POLL_SECONDS = 0.05
TEST_SEAM = "MACSCOPE_OPERABILITY_TEST_SEAMS"
TEST_AUTHORITY = "MACSCOPE_OPERABILITY_TEST_AUTHORITY"
TEST_GUI_DIRECT = "MACSCOPE_OPERABILITY_TEST_GUI_DIRECT"
TEST_GUI_OBSERVABLE = "MACSCOPE_OPERABILITY_TEST_GUI_OBSERVABLE"
TEST_ONLY_ENVIRONMENT = frozenset(
    {TEST_AUTHORITY, TEST_GUI_DIRECT, TEST_GUI_OBSERVABLE}
)


class SmokeFailure(RuntimeError):
    pass


def fail(message: str) -> NoReturn:
    raise SmokeFailure(message)


def bounded_text(value: bytes | str) -> str:
    payload = value.encode("utf-8", "replace") if isinstance(value, str) else value
    return (
        payload[:MAX_DIAGNOSTIC_BYTES]
        .decode("utf-8", "replace")
        .replace("\n", " ")
        .replace("\x00", "�")
    )


def metadata_tuple(value: os.stat_result) -> tuple[int, ...]:
    return (
        value.st_dev,
        value.st_ino,
        value.st_mode,
        value.st_nlink,
        value.st_size,
        value.st_mtime_ns,
        value.st_ctime_ns,
    )


def canonical_existing(path: Path, *, directory: bool, label: str) -> Path:
    if not path.is_absolute():
        fail(f"{label} must be an absolute path: {path}")
    try:
        canonical = path.resolve(strict=True)
        observed = path.lstat()
    except OSError as error:
        fail(f"{label} is unavailable: {error}")
    if canonical != path:
        fail(f"{label} must be canonical and must not traverse a symlink: {path}")
    if stat.S_ISLNK(observed.st_mode):
        fail(f"{label} must not be a symlink: {path}")
    expected = stat.S_ISDIR if directory else stat.S_ISREG
    if not expected(observed.st_mode):
        kind = "directory" if directory else "file"
        fail(f"{label} must be an ordinary {kind}: {path}")
    if not directory and observed.st_nlink != 1:
        fail(f"{label} must be a single-link regular file: {path}")
    return path


def stable_bytes(path: Path, *, label: str, maximum: int) -> tuple[bytes, str]:
    canonical_existing(path, directory=False, label=label)
    flags = (
        os.O_RDONLY
        | getattr(os, "O_NOFOLLOW", 0)
        | getattr(os, "O_CLOEXEC", 0)
    )
    try:
        descriptor = os.open(path, flags)
    except OSError as error:
        fail(f"{label} could not be opened: {error}")
    try:
        before = os.fstat(descriptor)
        if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1:
            fail(f"{label} must remain a single-link regular file")
        if before.st_size <= 0 or before.st_size > maximum:
            fail(f"{label} exceeds its bounded size contract")
        chunks: list[bytes] = []
        remaining = before.st_size
        while remaining:
            chunk = os.read(descriptor, min(1024 * 1024, remaining))
            if not chunk:
                break
            chunks.append(chunk)
            remaining -= len(chunk)
        after_descriptor = os.fstat(descriptor)
        after_path = path.lstat()
    except OSError as error:
        fail(f"{label} could not be read safely: {error}")
    finally:
        os.close(descriptor)
    payload = b"".join(chunks)
    if (
        len(payload) != before.st_size
        or metadata_tuple(before) != metadata_tuple(after_descriptor)
        or metadata_tuple(before) != metadata_tuple(after_path)
    ):
        fail(f"{label} changed while it was read")
    return payload, hashlib.sha256(payload).hexdigest()


def load_json(path: Path, *, label: str, canonical: bool = False) -> dict[str, Any]:
    payload, _ = stable_bytes(path, label=label, maximum=MAX_JSON_BYTES)
    try:
        if canonical:
            value = decode_canonical_bytes(payload)
        else:
            def closed_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
                result: dict[str, Any] = {}
                for key, item in pairs:
                    if key in result:
                        fail(f"{label} contains duplicate key {key!r}")
                    result[key] = item
                return result

            value = json.loads(
                payload.decode("utf-8"),
                object_pairs_hook=closed_object,
                parse_constant=lambda item: fail(f"{label} contains {item}"),
            )
    except (UnicodeDecodeError, json.JSONDecodeError, CanonicalJSONError) as error:
        fail(f"{label} is invalid JSON: {error}")
    if not isinstance(value, dict):
        fail(f"{label} must be a JSON object")
    return value


def validate_app_and_provenance(
    app: Path,
    candidate_commit: str,
) -> tuple[Path, str, str, str]:
    app = canonical_existing(app, directory=True, label="installed app")
    if app.name != "MacScope.app":
        fail("--app must name MacScope.app")
    executable = canonical_existing(
        app / EXECUTABLE_RELATIVE,
        directory=False,
        label="installed MacScope executable",
    )
    if not os.access(executable, os.X_OK):
        fail(f"installed MacScope executable is not executable: {executable}")
    _, executable_sha256 = stable_bytes(
        executable,
        label="installed MacScope executable",
        maximum=512 * 1024 * 1024,
    )
    provenance_path = app / PROVENANCE_RELATIVE
    provenance_payload, provenance_sha256 = stable_bytes(
        provenance_path,
        label="sealed Release provenance",
        maximum=1024 * 1024,
    )
    try:
        provenance = json.loads(provenance_payload.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        fail(f"sealed Release provenance is malformed: {error}")
    tree = provenance.get("git_head_tree") if isinstance(provenance, dict) else None
    inputs_digest = (
        provenance.get("selected_build_inputs_sha256")
        if isinstance(provenance, dict)
        else None
    )
    if (
        not isinstance(provenance, dict)
        or type(provenance.get("schema_version")) is not int
        or provenance.get("schema_version") != 1
        or provenance.get("qualification_eligible") is not True
        or provenance.get("configuration") != "Release"
        or provenance.get("repository_clean") is not True
        or provenance.get("git_head_commit") != candidate_commit
        or not isinstance(tree, str)
        or re.fullmatch(r"[0-9a-f]{40}", tree) is None
        or not isinstance(inputs_digest, str)
        or re.fullmatch(r"[0-9a-f]{64}", inputs_digest) is None
    ):
        fail("installed app is not the requested eligible sealed Release candidate")
    return executable, executable_sha256, provenance_sha256, str(tree)


def group_exists(process_group: int) -> bool:
    try:
        os.killpg(process_group, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def stop_group(proc: subprocess.Popen[bytes], *, label: str) -> None:
    process_group = proc.pid
    if group_exists(process_group):
        with contextlib.suppress(ProcessLookupError):
            os.killpg(process_group, signal.SIGTERM)
    deadline = time.monotonic() + STOP_GRACE_SECONDS
    while group_exists(process_group) and time.monotonic() < deadline:
        proc.poll()
        time.sleep(POLL_SECONDS)
    if group_exists(process_group):
        with contextlib.suppress(ProcessLookupError):
            os.killpg(process_group, signal.SIGKILL)
    with contextlib.suppress(subprocess.TimeoutExpired):
        proc.wait(timeout=STOP_GRACE_SECONDS)
    deadline = time.monotonic() + STOP_GRACE_SECONDS
    while group_exists(process_group) and time.monotonic() < deadline:
        proc.poll()
        time.sleep(POLL_SECONDS)
    if group_exists(process_group):
        fail(f"{label} left an owned process-group residue")


def capture_process(
    argv: list[str],
    *,
    environment: dict[str, str],
    timeout: float,
    label: str,
) -> tuple[int, bytes, bytes, int]:
    try:
        proc = subprocess.Popen(
            argv,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=environment,
            start_new_session=True,
        )
    except OSError as error:
        fail(f"{label} could not launch: {error}")
    assert proc.stdout is not None and proc.stderr is not None
    selector = selectors.DefaultSelector()
    selector.register(proc.stdout, selectors.EVENT_READ, "stdout")
    selector.register(proc.stderr, selectors.EVENT_READ, "stderr")
    captured = {"stdout": bytearray(), "stderr": bytearray()}
    deadline = time.monotonic() + timeout
    try:
        while selector.get_map():
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                fail(f"{label} timed out after {timeout:g}s")
            events = selector.select(min(remaining, 0.1))
            if not events and proc.poll() is not None:
                events = [
                    (key, selectors.EVENT_READ)
                    for key in selector.get_map().values()
                ]
            for key, _ in events:
                chunk = os.read(key.fileobj.fileno(), 8192)
                if not chunk:
                    selector.unregister(key.fileobj)
                    continue
                bucket = captured[key.data]
                bucket.extend(chunk)
                if len(bucket) > MAX_CAPTURE_BYTES:
                    fail(f"{label} {key.data} exceeded {MAX_CAPTURE_BYTES} bytes")
        status = proc.wait(timeout=max(0.1, deadline - time.monotonic()))
        if group_exists(proc.pid):
            stop_group(proc, label=label)
            fail(f"{label} left an owned process-group residue after exit")
        return status, bytes(captured["stdout"]), bytes(captured["stderr"]), proc.pid
    except (SmokeFailure, subprocess.TimeoutExpired):
        stop_group(proc, label=label)
        if isinstance(sys.exc_info()[1], subprocess.TimeoutExpired):
            fail(f"{label} timed out after {timeout:g}s")
        raise
    finally:
        selector.close()


def isolated_environment(root: Path) -> dict[str, str]:
    environment = os.environ.copy()
    environment.update(
        {
            "HOME": str(root / "home"),
            "CFFIXED_USER_HOME": str(root / "home"),
            "TMPDIR": str(root / "tmp"),
            "XDG_CACHE_HOME": str(root / "cache"),
            "XDG_CONFIG_HOME": str(root / "config"),
            "XDG_DATA_HOME": str(root / "data"),
            "HTTP_PROXY": "http://127.0.0.1:9",
            "HTTPS_PROXY": "http://127.0.0.1:9",
            "ALL_PROXY": "socks5://127.0.0.1:9",
            "NO_PROXY": "127.0.0.1,localhost,::1",
            "http_proxy": "http://127.0.0.1:9",
            "https_proxy": "http://127.0.0.1:9",
            "all_proxy": "socks5://127.0.0.1:9",
            "no_proxy": "127.0.0.1,localhost,::1",
        }
    )
    for name in ("home", "tmp", "cache", "config", "data"):
        (root / name).mkdir()
    return environment


def run_cli(executable: Path, binary: Path, timeout: float) -> int:
    binary = canonical_existing(binary, directory=False, label="CLI analysis binary")
    if not os.access(binary, os.R_OK):
        fail(f"CLI analysis binary is not readable: {binary}")
    with tempfile.TemporaryDirectory(prefix="macscope-cli-smoke-") as root:
        root_path = Path(root)
        environment = isolated_environment(root_path)
        script_path = root_path / "script.json"
        descriptor = os.open(
            script_path,
            os.O_WRONLY
            | os.O_CREAT
            | os.O_EXCL
            | getattr(os, "O_NOFOLLOW", 0),
            0o600,
        )
        try:
            os.write(descriptor, b'[{"command":"commands"}]')
            os.fsync(descriptor)
        finally:
            os.close(descriptor)
        status, stdout, stderr, pid = capture_process(
            [str(executable), "--run-script", str(script_path), str(binary)],
            environment=environment,
            timeout=timeout,
            label="CLI probe",
        )
    if status != 0:
        fail(f"CLI probe PID {pid} exited {status}: {bounded_text(stderr)}")
    try:
        result = json.loads(stdout.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        fail(f"CLI probe stdout was not one pure JSON value: {error}")
    if not isinstance(result, list) or not result:
        fail("CLI probe did not emit a non-empty JSON result")
    return pid


JXA_RUNNING_APPLICATIONS = r'''
ObjC.import('AppKit');
function run(argv) {
  const identifier = argv[0];
  const values = $.NSRunningApplication.runningApplicationsWithBundleIdentifier(identifier);
  const result = [];
  for (let index = 0; index < values.count; index += 1) {
    const app = values.objectAtIndex(index);
    const executable = app.executableURL;
    result.push({
      pid: Number(app.processIdentifier),
      executablePath: executable ? ObjC.unwrap(executable.path) : null,
      finishedLaunching: Boolean(app.finishedLaunching),
      activationPolicy: Number(app.activationPolicy)
    });
  }
  return JSON.stringify(result);
}
'''


def run_bounded_command(argv: list[str], *, timeout: float, label: str) -> bytes:
    status, stdout, stderr, _ = capture_process(
        argv,
        environment=os.environ.copy(),
        timeout=timeout,
        label=label,
    )
    if status != 0:
        fail(f"{label} exited {status}: {bounded_text(stderr)}")
    return stdout


def running_applications(timeout: float) -> list[dict[str, Any]]:
    stdout = run_bounded_command(
        [
            "/usr/bin/osascript",
            "-l",
            "JavaScript",
            "-e",
            JXA_RUNNING_APPLICATIONS,
            "org.macscope.app",
        ],
        timeout=timeout,
        label="LaunchServices application inventory",
    )
    try:
        value = json.loads(stdout.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        fail(f"LaunchServices application inventory was invalid: {error}")
    if not isinstance(value, list):
        fail("LaunchServices application inventory was not an array")
    return [item for item in value if isinstance(item, dict)]


def window_count(pid: int, timeout: float) -> int:
    script = (
        "on run argv\n"
        "set targetPID to (item 1 of argv) as integer\n"
        'tell application "System Events"\n'
        "set matches to every application process whose unix id is targetPID\n"
        'if (count of matches) is not 1 then return "missing"\n'
        "return (count of windows of item 1 of matches) as text\n"
        "end tell\n"
        "end run"
    )
    stdout = run_bounded_command(
        ["/usr/bin/osascript", "-e", script, str(pid)],
        timeout=timeout,
        label="GUI window observation",
    )
    value = stdout.decode("utf-8", "replace").strip()
    if value == "missing":
        return 0
    try:
        return max(0, int(value))
    except ValueError:
        fail(f"GUI window observation returned an invalid count: {bounded_text(value)}")


def stop_pid(pid: int, *, label: str) -> None:
    with contextlib.suppress(ProcessLookupError):
        os.kill(pid, signal.SIGTERM)
    deadline = time.monotonic() + STOP_GRACE_SECONDS
    while time.monotonic() < deadline:
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            return
        time.sleep(POLL_SECONDS)
    with contextlib.suppress(ProcessLookupError):
        os.kill(pid, signal.SIGKILL)
    deadline = time.monotonic() + STOP_GRACE_SECONDS
    while time.monotonic() < deadline:
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            return
        time.sleep(POLL_SECONDS)
    fail(f"{label} PID {pid} could not be retired")


def run_gui_test_seam(executable: Path, timeout: float) -> int:
    if os.environ.get(TEST_GUI_DIRECT) != "1":
        fail(f"{TEST_GUI_DIRECT} must be exactly 1 in the explicit test seam")
    with tempfile.TemporaryDirectory(prefix="macscope-gui-smoke-") as root:
        proc = subprocess.Popen(
            [str(executable)],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=isolated_environment(Path(root)),
            start_new_session=True,
        )
        deadline = time.monotonic() + timeout
        try:
            while time.monotonic() < deadline:
                if proc.poll() is not None:
                    fail(f"GUI probe PID {proc.pid} exited before observability")
                if os.environ.get(TEST_GUI_OBSERVABLE) == "1":
                    stop_group(proc, label="GUI probe")
                    return proc.pid
                time.sleep(POLL_SECONDS)
            fail("GUI process remained present but never became GUI-observable")
        except SmokeFailure:
            stop_group(proc, label="GUI probe")
            raise


def run_gui(app: Path, executable: Path, timeout: float, *, test_seams: bool) -> int:
    if test_seams:
        return run_gui_test_seam(executable, timeout)
    baseline = {
        int(item["pid"])
        for item in running_applications(min(2.0, timeout))
        if type(item.get("pid")) is int
    }
    run_bounded_command(
        ["/usr/bin/open", "-n", "-F", str(app)],
        timeout=min(5.0, timeout),
        label="LaunchServices GUI launch",
    )
    deadline = time.monotonic() + timeout
    launched_pid: int | None = None
    observed_process = False
    try:
        while time.monotonic() < deadline:
            remaining = max(POLL_SECONDS, deadline - time.monotonic())
            applications = running_applications(min(2.0, remaining))
            exact = [
                item
                for item in applications
                if type(item.get("pid")) is int
                and int(item["pid"]) not in baseline
                and item.get("executablePath") == str(executable)
            ]
            if len(exact) > 1:
                fail("GUI launch produced multiple new exact installed-app processes")
            if exact:
                observed_process = True
                item = exact[0]
                launched_pid = int(item["pid"])
                if (
                    item.get("finishedLaunching") is True
                    and item.get("activationPolicy") == 0
                    and window_count(launched_pid, min(2.0, remaining)) > 0
                ):
                    stop_pid(launched_pid, label="GUI probe")
                    return launched_pid
            time.sleep(POLL_SECONDS)
    finally:
        if launched_pid is not None:
            with contextlib.suppress(SmokeFailure):
                stop_pid(launched_pid, label="GUI probe")
    if observed_process:
        fail(
            "GUI process was present but never proved finished LaunchServices "
            "UI/window observability"
        )
    fail("LaunchServices did not expose a new process for the exact installed app")


AUTHORITY_ARGUMENTS = (
    "source_app",
    "candidate_identity",
    "qualification_run_id",
    "qualification_run_nonce",
    "installation_pending_state",
    "full_surface_report",
    "legacy_grid_report",
    "native_xpc_execution_report",
)


def validate_test_environment() -> bool:
    seam = os.environ.get(TEST_SEAM, "")
    if seam not in ("", "1"):
        fail(f"{TEST_SEAM} must be unset or exactly 1")
    overrides = sorted(name for name in TEST_ONLY_ENVIRONMENT if os.environ.get(name))
    if overrides and seam != "1":
        fail("operability test overrides require the explicit test seam")
    return seam == "1"


def load_authority(
    arguments: argparse.Namespace,
    *,
    executable_sha256: str,
    provenance_sha256: str,
    source_tree: str,
    observed_at_unix_ns: int,
    test_seams: bool,
) -> dict[str, Any]:
    if test_seams and os.environ.get(TEST_AUTHORITY):
        authority = load_json(
            Path(os.environ[TEST_AUTHORITY]),
            label="test operability authority",
            canonical=True,
        )
        bridge.require_closed_record(
            authority,
            bridge.OPERABILITY_AUTHORITY_FIELDS,
            path="test operability authority",
        )
    else:
        missing = [
            name
            for name in AUTHORITY_ARGUMENTS
            if getattr(arguments, name) in (None, "")
        ]
        if missing:
            fail(
                "--output requires exact operability authority inputs: "
                + ", ".join(missing)
            )
        try:
            authority, _, _ = bridge.validate_operability_authority(
                installed_app=arguments.app,
                source_app=arguments.source_app,
                candidate_identity=arguments.candidate_identity,
                expected_source_commit=arguments.candidate_commit,
                qualification_run_id=arguments.qualification_run_id,
                qualification_run_nonce=arguments.qualification_run_nonce,
                installation_pending_state=arguments.installation_pending_state,
                full_surface_report=arguments.full_surface_report,
                legacy_grid_report=arguments.legacy_grid_report,
                native_xpc_execution_report=arguments.native_xpc_execution_report,
            )
        except bridge.ReportError as error:
            fail(f"operability authority is invalid: {error}")
    if (
        authority.get("applicationExecutableSHA256") != executable_sha256
        or authority.get("installedExecutableSHA256") != executable_sha256
        or authority.get("buildProvenanceSHA256") != provenance_sha256
        or authority.get("sourceCommit") != arguments.candidate_commit
        or authority.get("sourceTree") != source_tree
        or type(authority.get("exposedAtUnixNanoseconds")) is not int
        or int(authority["exposedAtUnixNanoseconds"]) > observed_at_unix_ns
    ):
        fail(
            "operability authority is stale, synthetic, or bound to another "
            "installed candidate"
        )
    return dict(authority)


def validate_report_slot(output: Path) -> Path:
    if not output.is_absolute():
        fail("operability report output must be absolute")
    if output.exists() or output.is_symlink():
        fail("operability report output must be absent (create-only)")
    try:
        parent = output.parent.resolve(strict=True)
        parent_metadata = output.parent.lstat()
    except OSError as error:
        fail(f"operability report parent is unavailable: {error}")
    if (
        parent != output.parent
        or not stat.S_ISDIR(parent_metadata.st_mode)
        or stat.S_ISLNK(parent_metadata.st_mode)
    ):
        fail("operability report parent must be one canonical non-symlink directory")
    return parent


def create_report(output: Path, document: dict[str, Any], *, exposed_at: int) -> str:
    validate_report_slot(output)
    payload = canonical_bytes(document)
    if len(payload) > bridge.MAXIMUM_OPERABILITY_OUTPUT_BYTES:
        fail("operability report exceeds its bounded output contract")
    flags = (
        os.O_WRONLY
        | os.O_CREAT
        | os.O_EXCL
        | getattr(os, "O_NOFOLLOW", 0)
        | getattr(os, "O_CLOEXEC", 0)
    )
    try:
        descriptor = os.open(output, flags, 0o600)
        try:
            offset = 0
            while offset < len(payload):
                offset += os.write(descriptor, payload[offset:])
            os.fsync(descriptor)
            written = os.fstat(descriptor)
        finally:
            os.close(descriptor)
        observed_payload, digest = stable_bytes(
            output,
            label="operability report",
            maximum=bridge.MAXIMUM_OPERABILITY_OUTPUT_BYTES,
        )
    except OSError as error:
        fail(f"operability report could not be created: {error}")
    if (
        observed_payload != payload
        or written.st_nlink != 1
        or written.st_mtime_ns < exposed_at
        or output.resolve(strict=True) != output
    ):
        fail(
            "operability report publication did not preserve canonical "
            "single-link freshness"
        )
    return digest


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Bounded installed MacScope CLI/GUI operability smoke"
    )
    parser.add_argument(
        "--preflight",
        action="store_true",
        help="Validate the repository harness only",
    )
    parser.add_argument(
        "--mode",
        choices=("preflight", "cli", "gui", "both"),
        default="preflight",
    )
    parser.add_argument("--app", type=Path, default=DEFAULT_APP)
    parser.add_argument("--timeout-seconds", type=float, default=10.0)
    parser.add_argument("--binary", type=Path, default=DEFAULT_BINARY)
    parser.add_argument("--candidate-commit", default="")
    parser.add_argument("--output", "--report", dest="output", type=Path)
    parser.add_argument("--source-app", type=Path)
    parser.add_argument("--candidate-identity", type=Path)
    parser.add_argument("--qualification-run-id")
    parser.add_argument("--qualification-run-nonce")
    parser.add_argument("--installation-pending-state", type=Path)
    parser.add_argument("--full-surface-report", type=Path)
    parser.add_argument("--legacy-grid-report", type=Path)
    parser.add_argument("--native-xpc-execution-report", type=Path)
    arguments = parser.parse_args()
    if arguments.preflight:
        if arguments.mode != "preflight":
            fail("--preflight cannot be combined with an installed --mode")
        arguments.mode = "preflight"
    if not (1.0 <= arguments.timeout_seconds <= 60.0):
        fail("--timeout-seconds must be between 1 and 60")
    return arguments


def main() -> int:
    arguments = parse_arguments()
    test_seams = validate_test_environment()
    if arguments.mode == "preflight":
        canonical_existing(
            SCRIPT_DIR / "cli_gui_operability_smoke.sh",
            directory=False,
            label="harness",
        )
        canonical_existing(
            REPOSITORY_ROOT / "Scripts/tests/test_cli_gui_operability_smoke.py",
            directory=False,
            label="focused harness test",
        )
        print("PASS: repository preflight (offline, no Xcode, no app launch)")
        return 0
    if re.fullmatch(r"[0-9a-f]{40}", arguments.candidate_commit) is None:
        fail("--candidate-commit must be the exact lowercase 40-hex Release commit")
    if arguments.output is not None and arguments.mode != "both":
        fail("a bridge-grade CLI/GUI report requires --mode both")
    if arguments.output is not None:
        validate_report_slot(arguments.output)
    started_at_unix_ns = time.time_ns()
    executable, executable_sha256, provenance_sha256, source_tree = (
        validate_app_and_provenance(arguments.app, arguments.candidate_commit)
    )
    original_executable_sha256 = executable_sha256
    authority: dict[str, Any] | None = None
    if arguments.output is not None:
        authority = load_authority(
            arguments,
            executable_sha256=executable_sha256,
            provenance_sha256=provenance_sha256,
            source_tree=source_tree,
            observed_at_unix_ns=started_at_unix_ns,
            test_seams=test_seams,
        )
    probes = {"cli": False, "gui": False}
    launch_pids: dict[str, int] = {}
    if arguments.mode in ("cli", "both"):
        launch_pids["cli"] = run_cli(
            executable,
            arguments.binary,
            arguments.timeout_seconds,
        )
        probes["cli"] = True
    if arguments.mode in ("gui", "both"):
        launch_pids["gui"] = run_gui(
            arguments.app,
            executable,
            arguments.timeout_seconds,
            test_seams=test_seams,
        )
        probes["gui"] = True
    current_executable_sha256 = stable_bytes(
        executable,
        label="installed MacScope executable",
        maximum=512 * 1024 * 1024,
    )[1]
    if current_executable_sha256 != original_executable_sha256:
        fail("installed MacScope executable changed during operability probes")
    if arguments.output is not None:
        assert authority is not None
        final_authority = load_authority(
            arguments,
            executable_sha256=executable_sha256,
            provenance_sha256=provenance_sha256,
            source_tree=source_tree,
            observed_at_unix_ns=time.time_ns(),
            test_seams=test_seams,
        )
        if final_authority != authority:
            fail("operability authority changed during CLI/GUI probes")
        document = bridge.operability_report_document(
            report_kind=bridge.CLI_GUI_OPERABILITY_REPORT_KIND,
            probe_results=probes,
            authority=authority,
        )
        digest = create_report(
            arguments.output,
            document,
            exposed_at=int(authority["exposedAtUnixNanoseconds"]),
        )
        print(f"PASS: installed CLI/GUI operability report sha256={digest}")
    else:
        completed = "/".join(name for name, passed in probes.items() if passed)
        print(f"PASS: installed {completed} launch/readiness probe")
    return 0


try:
    raise SystemExit(main())
except SmokeFailure as error:
    print(f"ERROR: {bounded_text(str(error))}", file=sys.stderr)
    raise SystemExit(1)
except KeyboardInterrupt:
    print("ERROR: interrupted", file=sys.stderr)
    raise SystemExit(130)
except Exception as error:
    print(
        f"ERROR: unexpected smoke failure: {bounded_text(str(error))}",
        file=sys.stderr,
    )
    raise SystemExit(1)
PY
