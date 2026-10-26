#!/bin/bash
set -euo pipefail

# Bounded, stdio-only MCP smoke for the exact installed MacScope executable.
# A final installed run can emit the exact closed report accepted by the
# installed-operability bridge.
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
exec /usr/bin/python3 -B - "$SCRIPT_DIR" "$@" <<'PY'
from __future__ import annotations

import argparse
import contextlib
import hashlib
import json
import os
import re
import select
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


MAX_LINE_BYTES = 64 * 1024
MAX_STDERR_BYTES = 64 * 1024
MAX_JSON_BYTES = 4 * 1024 * 1024
MAX_DIAGNOSTIC_BYTES = 512
# The navigator surface the headless MCP server must list. The two mutating commands are the only
# ones whose tools/list description says so; the rest are read-only.
NAVIGATOR_READ_TOOLS = (
    "navigator-facts",
    "navigator-frontier",
    "navigator-dependents",
    "navigator-primitives",
    "navigator-preview-revert",
    "navigator-toolchain",
    "navigator-resolve-provenance",
)
NAVIGATOR_MUTATING_TOOLS = ("navigator-accept", "navigator-revert")
DEFAULT_TIMEOUT = 10.0
STARTUP_ACTIVITY_TIMEOUT_SECONDS = 5.0
DEFAULT_APP = Path("/Applications/MacScope.app")
DEFAULT_BINARY = Path("/bin/ls")
EXECUTABLE_RELATIVE = Path("Contents/MacOS/MacScope")
PROVENANCE_RELATIVE = Path("Contents/Resources/MacScopeBuildProvenance.json")
STOP_GRACE_SECONDS = 1.0
TEST_SEAM = "MACSCOPE_OPERABILITY_TEST_SEAMS"
TEST_AUTHORITY = "MACSCOPE_OPERABILITY_TEST_AUTHORITY"


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


def require_navigator_tools(entries: list[Any]) -> None:
    by_name = {
        tool.get("name"): tool for tool in entries if isinstance(tool, dict)
    }
    for name in NAVIGATOR_READ_TOOLS + NAVIGATOR_MUTATING_TOOLS:
        tool = by_name.get(name)
        if not isinstance(tool, dict) or not isinstance(tool.get("inputSchema"), dict):
            fail(f"MCP tools/list did not expose {name} with a schema")
        mutating = "mutates the workspace" in str(tool.get("description", ""))
        if mutating != (name in NAVIGATOR_MUTATING_TOOLS):
            fail(f"MCP tools/list reported the wrong mutation flag for {name}")


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
        value = decode_canonical_bytes(payload) if canonical else json.loads(payload)
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
    provenance_payload, provenance_sha256 = stable_bytes(
        app / PROVENANCE_RELATIVE,
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


def validate_macho(path: Path) -> None:
    try:
        result = subprocess.run(
            ["/usr/bin/file", "-b", str(path)],
            capture_output=True,
            timeout=2.0,
            check=False,
        )
    except (OSError, subprocess.SubprocessError) as error:
        fail(f"could not inspect analysis binary with file: {error}")
    if (
        result.returncode != 0
        or len(result.stdout) > MAX_LINE_BYTES
        or len(result.stderr) > MAX_STDERR_BYTES
        or b"Mach-O" not in result.stdout
    ):
        fail(f"analysis binary is not a bounded Mach-O: {bounded_text(result.stdout)}")


def group_exists(process_group: int) -> bool:
    try:
        os.killpg(process_group, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def stop_group(proc: subprocess.Popen[bytes]) -> None:
    process_group = proc.pid
    if group_exists(process_group):
        with contextlib.suppress(ProcessLookupError):
            os.killpg(process_group, signal.SIGTERM)
    deadline = time.monotonic() + STOP_GRACE_SECONDS
    while group_exists(process_group) and time.monotonic() < deadline:
        proc.poll()
        time.sleep(0.05)
    if group_exists(process_group):
        with contextlib.suppress(ProcessLookupError):
            os.killpg(process_group, signal.SIGKILL)
    with contextlib.suppress(subprocess.TimeoutExpired):
        proc.wait(timeout=STOP_GRACE_SECONDS)
    deadline = time.monotonic() + STOP_GRACE_SECONDS
    while group_exists(process_group) and time.monotonic() < deadline:
        proc.poll()
        time.sleep(0.05)
    if group_exists(process_group):
        fail("MCP server left an owned process-group residue")


class MCPTransport:
    def __init__(self, executable: Path, binary: Path, environment: dict[str, str]) -> None:
        try:
            self.proc = subprocess.Popen(
                [str(executable), "--mcp", str(binary)],
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                env=environment,
                start_new_session=True,
            )
        except OSError as error:
            fail(f"MacScope MCP server could not launch: {error}")
        assert self.proc.stdin is not None
        assert self.proc.stdout is not None
        assert self.proc.stderr is not None
        self.stdin_fd = self.proc.stdin.fileno()
        self.stdout_fd = self.proc.stdout.fileno()
        self.stderr_fd = self.proc.stderr.fileno()
        os.set_blocking(self.stdin_fd, False)
        os.set_blocking(self.stdout_fd, False)
        os.set_blocking(self.stderr_fd, False)
        self.stdout_buffer = bytearray()
        self.stderr_buffer = bytearray()

    @property
    def pid(self) -> int:
        return self.proc.pid

    def _remaining(self, deadline: float) -> float:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            fail("MCP protocol deadline expired")
        return remaining

    def _record_stderr(self, chunk: bytes) -> None:
        self.stderr_buffer.extend(chunk)
        if len(self.stderr_buffer) > MAX_STDERR_BYTES:
            fail(f"MCP stderr exceeded {MAX_STDERR_BYTES} bytes")

    def _record_stdout(self, chunk: bytes) -> None:
        self.stdout_buffer.extend(chunk)
        if len(self.stdout_buffer) > MAX_LINE_BYTES:
            fail(f"MCP stdout exceeded the {MAX_LINE_BYTES}-byte line bound")

    def _drain_ready(
        self,
        deadline: float,
        *,
        need_stdout_line: bool,
        timeout_message: str,
    ) -> bool:
        readable, _, _ = select.select(
            [self.stdout_fd, self.stderr_fd],
            [],
            [],
            self._remaining(deadline),
        )
        if not readable:
            fail(timeout_message)
        observed_activity = False
        for descriptor in readable:
            try:
                chunk = os.read(descriptor, 8192)
            except BlockingIOError:
                continue
            if descriptor == self.stderr_fd:
                if chunk:
                    observed_activity = True
                    self._record_stderr(chunk)
            elif chunk:
                observed_activity = True
                self._record_stdout(chunk)
            elif need_stdout_line and b"\n" not in self.stdout_buffer:
                fail("MacScope MCP server closed stdout before replying")
        return observed_activity

    def send(self, value: dict[str, Any], deadline: float) -> None:
        wire = json.dumps(value, sort_keys=True, separators=(",", ":")).encode() + b"\n"
        if len(wire) > MAX_LINE_BYTES:
            fail("MCP request exceeded the bounded line limit")
        offset = 0
        while offset < len(wire):
            readable, writable, _ = select.select(
                [self.stderr_fd],
                [self.stdin_fd],
                [],
                self._remaining(deadline),
            )
            if self.stderr_fd in readable:
                try:
                    chunk = os.read(self.stderr_fd, 8192)
                except BlockingIOError:
                    chunk = b""
                if chunk:
                    self._record_stderr(chunk)
            if self.stdin_fd not in writable:
                continue
            try:
                written = os.write(self.stdin_fd, wire[offset:])
            except (BrokenPipeError, OSError) as error:
                fail(f"MCP request write failed: {error}")
            if written <= 0:
                fail("MCP request write made no progress")
            offset += written

    def response(
        self,
        request_id: int,
        deadline: float,
        *,
        first_activity_budget: float | None = None,
    ) -> dict[str, Any]:
        awaiting_startup_activity = first_activity_budget is not None
        response_deadline = deadline
        while b"\n" not in self.stdout_buffer:
            observed_activity = self._drain_ready(
                response_deadline,
                need_stdout_line=True,
                timeout_message=(
                    "MCP startup readiness timeout"
                    if awaiting_startup_activity
                    else "MCP response timeout"
                ),
            )
            if awaiting_startup_activity and observed_activity:
                assert first_activity_budget is not None
                response_deadline = time.monotonic() + first_activity_budget
                awaiting_startup_activity = False
        raw, _, remainder = self.stdout_buffer.partition(b"\n")
        self.stdout_buffer = bytearray(remainder)
        if not raw or len(raw) + 1 > MAX_LINE_BYTES:
            fail("MCP response violated the bounded newline-delimited frame")
        try:
            response = json.loads(raw)
        except (UnicodeDecodeError, json.JSONDecodeError) as error:
            fail(f"MCP response was not JSON: {error}")
        if not isinstance(response, dict):
            fail("MCP response must be a JSON object")
        if response.get("jsonrpc") != "2.0":
            fail("MCP response jsonrpc must be 2.0")
        if type(response.get("id")) is not int or response.get("id") != request_id:
            fail(
                f"MCP response id mismatch: expected {request_id}, "
                f"got {response.get('id')!r}"
            )
        has_result = "result" in response
        has_error = "error" in response
        if has_result == has_error:
            fail("MCP response must contain exactly one of result or error")
        if has_error:
            error = response["error"]
            if (
                not isinstance(error, dict)
                or type(error.get("code")) is not int
                or not isinstance(error.get("message"), str)
            ):
                fail("MCP error must contain integer code and string message")
            fail(f"MCP request failed ({error['code']}): {error['message']}")
        result = response["result"]
        if not isinstance(result, dict):
            fail("MCP response result must be an object")
        return result

    def request(
        self,
        request_id: int,
        method: str,
        params: dict[str, Any],
        deadline: float,
        *,
        first_activity_budget: float | None = None,
    ) -> dict[str, Any]:
        self.send(
            {
                "jsonrpc": "2.0",
                "id": request_id,
                "method": method,
                "params": params,
            },
            deadline,
        )
        return self.response(
            request_id,
            deadline,
            first_activity_budget=first_activity_budget,
        )

    def notification(self, method: str, deadline: float) -> None:
        self.send({"jsonrpc": "2.0", "method": method}, deadline)

    def require_stdout_quiet(self, deadline: float) -> None:
        quiet_deadline = min(deadline, time.monotonic() + 0.05)
        while time.monotonic() < quiet_deadline:
            readable, _, _ = select.select(
                [self.stdout_fd, self.stderr_fd],
                [],
                [],
                max(0.0, quiet_deadline - time.monotonic()),
            )
            if not readable:
                break
            for descriptor in readable:
                try:
                    chunk = os.read(descriptor, 8192)
                except BlockingIOError:
                    continue
                if descriptor == self.stderr_fd:
                    if chunk:
                        self._record_stderr(chunk)
                elif chunk:
                    self._record_stdout(chunk)
        if self.stdout_buffer:
            fail("MCP server contaminated stdout after the final JSON-RPC response")

    def close(self) -> None:
        stop_group(self.proc)


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


def run_installed(executable: Path, binary: Path, timeout: float) -> tuple[int, dict[str, bool]]:
    binary = canonical_existing(binary, directory=False, label="analysis binary")
    validate_macho(binary)
    with tempfile.TemporaryDirectory(prefix="macscope-mcp-smoke-") as root:
        transport = MCPTransport(
            executable,
            binary,
            isolated_environment(Path(root)),
        )
        probes = {"initialize": False, "readOnlyInfo": False, "toolsList": False}
        try:
            startup_deadline = time.monotonic() + STARTUP_ACTIVITY_TIMEOUT_SECONDS
            initialize = transport.request(
                1,
                "initialize",
                {
                    "protocolVersion": "2024-11-05",
                    "capabilities": {},
                    "clientInfo": {"name": "macscope-mcp-smoke", "version": "1"},
                },
                startup_deadline,
                first_activity_budget=timeout,
            )
            server_info = initialize.get("serverInfo")
            if (
                initialize.get("protocolVersion") != "2024-11-05"
                or not isinstance(server_info, dict)
                or server_info.get("name") != "macscope"
            ):
                fail("MCP initialize result does not identify the expected protocol/server")
            probes["initialize"] = True
            deadline = time.monotonic() + timeout
            transport.notification("notifications/initialized", deadline)
            tools_result = transport.request(2, "tools/list", {}, deadline)
            entries = tools_result.get("tools")
            if not isinstance(entries, list):
                fail("MCP tools/list result does not contain a tools array")
            info = next(
                (
                    tool
                    for tool in entries
                    if isinstance(tool, dict) and tool.get("name") == "info"
                ),
                None,
            )
            if (
                not isinstance(info, dict)
                or not isinstance(info.get("inputSchema"), dict)
                or "mutates the workspace" in str(info.get("description", ""))
            ):
                fail("MCP tools/list did not expose read-only info with a schema")
            require_navigator_tools(entries)
            probes["toolsList"] = True
            result = transport.request(
                3,
                "tools/call",
                {"name": "info", "arguments": {}},
                deadline,
            )
            if (
                result.get("isError") is not False
                or not isinstance(result.get("content"), list)
                or len(result["content"]) != 1
            ):
                fail("MCP read-only info call returned an invalid tool result")
            content = result["content"][0]
            if (
                not isinstance(content, dict)
                or content.get("type") != "text"
                or not isinstance(content.get("text"), str)
            ):
                fail("MCP read-only info call returned invalid text content")
            try:
                payload = json.loads(content["text"])
            except json.JSONDecodeError as error:
                fail(f"MCP info tool content was not JSON: {error}")
            if not isinstance(payload, dict) or payload.get("format") != "Mach-O executable":
                fail("MCP info tool did not report the supplied Mach-O as an executable")
            probes["readOnlyInfo"] = True
            transport.require_stdout_quiet(deadline)
            return transport.pid, probes
        finally:
            transport.close()


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
    if os.environ.get(TEST_AUTHORITY) and seam != "1":
        fail("operability test authority requires the explicit test seam")
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
        description="Bounded installed MacScope MCP/JSON-RPC operability smoke"
    )
    parser.add_argument("--mode", choices=("preflight", "installed"), required=True)
    parser.add_argument("--app", type=Path, default=DEFAULT_APP)
    parser.add_argument("--binary", type=Path, default=DEFAULT_BINARY)
    parser.add_argument("--candidate-commit", default="")
    parser.add_argument("--timeout-seconds", type=float, default=DEFAULT_TIMEOUT)
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
    if not (0.1 <= arguments.timeout_seconds <= 60.0):
        fail("--timeout-seconds must be between 0.1 and 60")
    if arguments.output is not None and arguments.mode != "installed":
        fail("a bridge-grade MCP report requires --mode installed")
    if arguments.output is not None:
        validate_report_slot(arguments.output)
    return arguments


def main() -> int:
    arguments = parse_arguments()
    test_seams = validate_test_environment()
    if arguments.mode == "preflight":
        canonical_existing(arguments.app, directory=True, label="installed app")
        canonical_existing(
            arguments.app / EXECUTABLE_RELATIVE,
            directory=False,
            label="installed MacScope executable",
        )
        canonical_existing(arguments.binary, directory=False, label="analysis binary")
        print("PASS: MCP preflight passed without Xcode or launching MacScope")
        return 0
    if re.fullmatch(r"[0-9a-f]{40}", arguments.candidate_commit) is None:
        fail("--candidate-commit must be the exact lowercase 40-hex Release commit")
    started_at_unix_ns = time.time_ns()
    executable, executable_sha256, provenance_sha256, source_tree = (
        validate_app_and_provenance(arguments.app, arguments.candidate_commit)
    )
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
    _, probes = run_installed(executable, arguments.binary, arguments.timeout_seconds)
    current_executable_sha256 = stable_bytes(
        executable,
        label="installed MacScope executable",
        maximum=512 * 1024 * 1024,
    )[1]
    if current_executable_sha256 != executable_sha256:
        fail("installed MacScope executable changed during the MCP probe")
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
            fail("operability authority changed during the MCP probe")
        document = bridge.operability_report_document(
            report_kind=bridge.MCP_OPERABILITY_REPORT_KIND,
            probe_results=probes,
            authority=authority,
        )
        digest = create_report(
            arguments.output,
            document,
            exposed_at=int(authority["exposedAtUnixNanoseconds"]),
        )
        print(f"PASS: installed MCP operability report sha256={digest}")
    else:
        print("PASS: installed MCP initialize, tools/list, and read-only info call")
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
