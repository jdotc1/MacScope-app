#!/usr/bin/env python3
"""Supervise the shadow-only DCP-03B3 libghidra native decompiler pilot."""

from __future__ import annotations

import argparse
import json
import math
import os
import pathlib
import re
import resource
import signal
import stat
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass
from typing import Any, Sequence

ROOT = pathlib.Path(__file__).resolve().parents[2]
CORE_TOOL_ROOT = ROOT / "Tools" / "DecompilerCoreProof"
NATIVE_TOOL_ROOT = ROOT / "Tools" / "NativeDecompilerPilot"
sys.path[:0] = [str(NATIVE_TOOL_ROOT), str(CORE_TOOL_ROOT)]

from macscope_decompiler_proof.canonical import canonical_json_bytes, canonical_sha256
from macscope_decompiler_proof.errors import ProofError
from macscope_decompiler_proof.request import MAX_REQUEST_BYTES, AnalysisRequest, parse_request_bytes
from macscope_native_decompiler_pilot.contract import RESULT_SCHEMA_VERSION
from macscope_native_decompiler_pilot.result_validation import ResultValidationError, validate_result

STARTUP_ALLOWANCE_SECONDS = 5.0
MAX_ADDRESS_SPACE_BYTES = 4 * 1024 * 1024 * 1024
MAX_OPEN_FILES = 96
MAX_CHILD_ERROR_BYTES = 64 * 1024
_ERROR_CODE = re.compile(r"^[a-z0-9][a-z0-9._-]{0,127}$")


@dataclass(frozen=True)
class SupervisorError(RuntimeError):
    code: str
    message: str
    exit_code: int = 2

    def __str__(self) -> str:
        return self.message


def parser() -> argparse.ArgumentParser:
    value = argparse.ArgumentParser(description="Supervise the MacScope DCP-03B3 native decompiler pilot")
    value.add_argument("--python", required=True, help="Python executable for the isolated pilot")
    value.add_argument("--materialization", required=True, help="exact libghidra MATERIALIZATION.json")
    value.add_argument("--input", required=True, help="validated DCP-03 request")
    value.add_argument("--output", required=True, help="canonical pilot result")
    value.add_argument("--cancel-file", default=None)
    return value


def _read_regular(path: pathlib.Path, *, maximum: int, label: str, allow_symlink: bool = False) -> bytes:
    try:
        before = path.lstat()
    except OSError as error:
        raise SupervisorError("supervisor.invalid_configuration", f"{label} is missing or inaccessible") from error
    allowed = stat.S_ISREG(before.st_mode) or (allow_symlink and stat.S_ISLNK(before.st_mode))
    if not allowed:
        raise SupervisorError("supervisor.invalid_configuration", f"{label} must be an ordinary file")
    if before.st_size > maximum and stat.S_ISREG(before.st_mode):
        raise SupervisorError("supervisor.invalid_configuration", f"{label} exceeds its fixed bound")
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0)
    if not allow_symlink:
        flags |= getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(path, flags)
    except OSError as error:
        raise SupervisorError("supervisor.invalid_configuration", f"{label} could not be opened safely") from error
    try:
        after = os.fstat(descriptor)
        if not stat.S_ISREG(after.st_mode):
            raise SupervisorError("supervisor.invalid_configuration", f"{label} must resolve to a regular file")
        if stat.S_ISREG(before.st_mode) and (before.st_dev, before.st_ino) != (after.st_dev, after.st_ino):
            raise SupervisorError("supervisor.invalid_configuration", f"{label} changed while opening")
        with os.fdopen(descriptor, "rb") as stream:
            descriptor = -1
            payload = stream.read(maximum + 1)
    finally:
        if descriptor >= 0:
            os.close(descriptor)
    if len(payload) > maximum:
        raise SupervisorError("supervisor.invalid_configuration", f"{label} exceeds its fixed bound")
    return payload


def _validate_python(path: pathlib.Path) -> pathlib.Path:
    absolute = path.absolute()
    try:
        unresolved = absolute.lstat()
        resolved = absolute.resolve(strict=True)
        resolved_metadata = resolved.lstat()
    except OSError as error:
        raise SupervisorError("supervisor.invalid_python", "pilot Python is missing or inaccessible") from error
    if not (stat.S_ISREG(unresolved.st_mode) or stat.S_ISLNK(unresolved.st_mode)):
        raise SupervisorError("supervisor.invalid_python", "pilot Python must be a regular file or symlink")
    if not stat.S_ISREG(resolved_metadata.st_mode) or not os.access(resolved, os.X_OK):
        raise SupervisorError("supervisor.invalid_python", "pilot Python must resolve to an executable file")
    return absolute


def _set_limit(kind: int, soft: int, hard: int | None = None) -> None:
    try:
        _current_soft, current_hard = resource.getrlimit(kind)
        desired_hard = soft if hard is None else hard
        if current_hard != resource.RLIM_INFINITY:
            desired_hard = min(desired_hard, current_hard)
        resource.setrlimit(kind, (min(soft, desired_hard), desired_hard))
    except (OSError, ValueError):
        pass


def _resource_limiter(timeout_seconds: float, maximum_output: int):
    def apply() -> None:
        _set_limit(resource.RLIMIT_CORE, 0, 0)
        if hasattr(resource, "RLIMIT_NOFILE"):
            _set_limit(resource.RLIMIT_NOFILE, MAX_OPEN_FILES)
        if hasattr(resource, "RLIMIT_FSIZE"):
            _set_limit(resource.RLIMIT_FSIZE, maximum_output + MAX_CHILD_ERROR_BYTES)
        if hasattr(resource, "RLIMIT_AS"):
            _set_limit(resource.RLIMIT_AS, MAX_ADDRESS_SPACE_BYTES)
        if hasattr(resource, "RLIMIT_CPU"):
            cpu_seconds = max(1, math.ceil(timeout_seconds))
            _set_limit(resource.RLIMIT_CPU, cpu_seconds, cpu_seconds + 1)
    return apply


def _cancelled(path: pathlib.Path | None) -> bool:
    if path is None:
        return False
    try:
        path.lstat()
    except FileNotFoundError:
        return False
    except OSError:
        return True
    return True


def _terminate_process_group(process: subprocess.Popen[bytes]) -> None:
    """Terminate the supervised child and every descendant in its session."""

    if process.poll() is not None:
        return
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    except OSError:
        try:
            process.kill()
        except ProcessLookupError:
            pass
    try:
        process.wait(timeout=2.0)
    except subprocess.TimeoutExpired:
        try:
            process.kill()
        except ProcessLookupError:
            pass
        process.wait()


def _same_path(left: pathlib.Path, right: pathlib.Path) -> bool:
    try:
        left_value = left.resolve(strict=True)
        if right.exists():
            return left_value == right.resolve(strict=True)
        return left_value == right.parent.resolve(strict=True) / right.name
    except OSError as error:
        raise SupervisorError("supervisor.invalid_configuration", "input or output path is unsafe") from error


def _error_payload(code: str, message: str, request_id: str | None) -> bytes:
    value: dict[str, object] = {
        "schemaVersion": 1,
        "status": "error",
        "requestId": request_id,
        "error": {"code": code, "message": message},
    }
    value["contentHash"] = canonical_sha256(value)
    return canonical_json_bytes(value)


def _duplicate_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate JSON key")
        result[key] = value
    return result


def _validated_child_error(payload: bytes, request_id: str) -> bytes | None:
    try:
        value = json.loads(payload.decode("utf-8"), object_pairs_hook=_duplicate_object)
    except (UnicodeDecodeError, json.JSONDecodeError, ValueError):
        return None
    if not isinstance(value, dict) or set(value) != {"schemaVersion", "status", "requestId", "error", "contentHash"}:
        return None
    if value.get("schemaVersion") != 1 or value.get("status") != "error" or value.get("requestId") not in (None, request_id):
        return None
    error = value.get("error")
    if not isinstance(error, dict) or set(error) != {"code", "message"}:
        return None
    code, message = error.get("code"), error.get("message")
    if not isinstance(code, str) or _ERROR_CODE.fullmatch(code) is None or not isinstance(message, str) or len(message) > 1024:
        return None
    unhashed = dict(value)
    del unhashed["contentHash"]
    if value.get("contentHash") != canonical_sha256(unhashed):
        return None
    return canonical_json_bytes(value)


def _validate_success(payload: bytes, request: AnalysisRequest) -> str | None:
    try:
        value = json.loads(payload.decode("utf-8"), object_pairs_hook=_duplicate_object)
    except (UnicodeDecodeError, json.JSONDecodeError, ValueError):
        return "pilot child emitted invalid canonical JSON"
    if not isinstance(value, dict) or value.get("schemaVersion") != RESULT_SCHEMA_VERSION or value.get("status") != "ok":
        return "pilot child emitted an unsupported success result"
    if value.get("requestId") != request.request_id or value.get("requestSha256") != request.request_sha256:
        return "pilot child result does not bind to the request"
    if canonical_json_bytes(value) != payload:
        return "pilot child result is not canonical JSON"
    try:
        validate_result(value, request=request)
    except ResultValidationError as error:
        return f"pilot child result failed semantic validation: {error}"
    return None


def _atomic_write(path: pathlib.Path, payload: bytes) -> None:
    parent = path.parent
    try:
        metadata = parent.lstat()
    except OSError as error:
        raise SupervisorError("output.write_failed", "output directory is inaccessible", 7) from error
    if not stat.S_ISDIR(metadata.st_mode) or stat.S_ISLNK(metadata.st_mode):
        raise SupervisorError("output.write_failed", "output directory must be ordinary", 7)
    try:
        existing = path.lstat()
    except FileNotFoundError:
        existing = None
    if existing is not None and (not stat.S_ISREG(existing.st_mode) or stat.S_ISLNK(existing.st_mode)):
        raise SupervisorError("output.write_failed", "output must be absent or ordinary", 7)
    descriptor = -1
    temporary: str | None = None
    try:
        descriptor, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=parent)
        os.fchmod(descriptor, 0o644)
        with os.fdopen(descriptor, "wb") as stream:
            descriptor = -1
            stream.write(payload)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
        temporary = None
    except OSError as error:
        raise SupervisorError("output.write_failed", "result could not be published atomically", 7) from error
    finally:
        if descriptor >= 0:
            os.close(descriptor)
        if temporary is not None:
            try:
                os.unlink(temporary)
            except OSError:
                pass


def main(argv: Sequence[str] | None = None) -> int:
    arguments = parser().parse_args(argv)
    request: AnalysisRequest | None = None
    try:
        input_path = pathlib.Path(arguments.input)
        output_path = pathlib.Path(arguments.output)
        materialization_path = pathlib.Path(arguments.materialization).absolute()
        payload = _read_regular(input_path, maximum=MAX_REQUEST_BYTES, label="input")
        request = parse_request_bytes(payload)
        invocation_python = _validate_python(pathlib.Path(arguments.python))
        _read_regular(materialization_path, maximum=64 * 1024, label="materialization manifest")
        if _same_path(input_path, output_path):
            raise SupervisorError("supervisor.invalid_configuration", "input and output must differ")
        cancellation_path = None if arguments.cancel_file is None else pathlib.Path(arguments.cancel_file).absolute()
        if _cancelled(cancellation_path):
            sys.stderr.buffer.write(_error_payload("analysis.cancelled", "analysis cancelled", request.request_id))
            return 6

        timeout_seconds = request.budgets.max_wall_time_ms / 1000.0 + STARTUP_ALLOWANCE_SECONDS
        tool_path = os.pathsep.join((str(NATIVE_TOOL_ROOT), str(CORE_TOOL_ROOT)))
        environment = {
            "HOME": "/tmp",
            "LANG": "C.UTF-8",
            "LC_ALL": "C.UTF-8",
            "PATH": "/usr/bin:/bin",
            "PYTHONHASHSEED": "0",
            "PYTHONDONTWRITEBYTECODE": "1",
            "PYTHONNOUSERSITE": "1",
            "PYTHONPATH": tool_path,
            "TMPDIR": "/tmp",
            "NO_PROXY": "*",
            "no_proxy": "*",
        }
        command = [
            str(invocation_python),
            "-m",
            "macscope_native_decompiler_pilot.cli",
            "--input",
            "-",
            "--output",
            "-",
            "--materialization",
            str(materialization_path),
        ]
        if cancellation_path is not None:
            command.extend(("--cancel-file", str(cancellation_path)))

        with tempfile.TemporaryFile() as stdout_file, tempfile.TemporaryFile() as stderr_file:
            process = subprocess.Popen(
                command,
                stdin=subprocess.PIPE,
                stdout=stdout_file,
                stderr=stderr_file,
                cwd=ROOT,
                env=environment,
                preexec_fn=_resource_limiter(timeout_seconds, request.budgets.max_output_bytes),
                start_new_session=True,
            )
            deadline = time.monotonic() + timeout_seconds
            communicate_input: bytes | None = payload
            try:
                while True:
                    if _cancelled(cancellation_path):
                        _terminate_process_group(process)
                        sys.stderr.buffer.write(
                            _error_payload("analysis.cancelled", "analysis cancelled", request.request_id)
                        )
                        return 6
                    remaining = deadline - time.monotonic()
                    if remaining <= 0:
                        _terminate_process_group(process)
                        sys.stderr.buffer.write(
                            _error_payload(
                                "resource.exhausted",
                                "external wall-clock limit exceeded",
                                request.request_id,
                            )
                        )
                        return 124
                    try:
                        process.communicate(communicate_input, timeout=min(0.1, remaining))
                        break
                    except subprocess.TimeoutExpired:
                        # subprocess retains the partially communicated input;
                        # subsequent calls continue without accepting it again.
                        communicate_input = None
            except BaseException:
                _terminate_process_group(process)
                raise
            stdout_file.seek(0)
            stdout = stdout_file.read(request.budgets.max_output_bytes + 1)
            stderr_file.seek(0)
            stderr = stderr_file.read(MAX_CHILD_ERROR_BYTES + 1)

        if len(stdout) > request.budgets.max_output_bytes:
            sys.stderr.buffer.write(_error_payload("resource.exhausted", "child output exceeded maxOutputBytes", request.request_id))
            return 125
        if len(stderr) > MAX_CHILD_ERROR_BYTES:
            sys.stderr.buffer.write(_error_payload("child.failed", "child diagnostic exceeded its bound", request.request_id))
            return 70
        if process.returncode != 0:
            child_error = _validated_child_error(stderr, request.request_id)
            if child_error is not None:
                sys.stderr.buffer.write(child_error)
                return process.returncode if 0 < process.returncode < 126 else 70
            sys.stderr.buffer.write(_error_payload("child.failed", "pilot child failed without a valid diagnostic", request.request_id))
            return 70
        if stderr:
            sys.stderr.buffer.write(_error_payload("child.invalid_output", "pilot child emitted unexpected diagnostics", request.request_id))
            return 70
        if _cancelled(cancellation_path):
            sys.stderr.buffer.write(_error_payload("analysis.cancelled", "analysis cancelled", request.request_id))
            return 6
        validation_error = _validate_success(stdout, request)
        if validation_error is not None:
            sys.stderr.buffer.write(_error_payload("child.invalid_output", validation_error, request.request_id))
            return 70
        _atomic_write(output_path, stdout)
        return 0
    except ProofError as error:
        sys.stderr.buffer.write(_error_payload(error.code, error.message, None if request is None else request.request_id))
        return error.exit_code
    except SupervisorError as error:
        sys.stderr.buffer.write(_error_payload(error.code, error.message, None if request is None else request.request_id))
        return error.exit_code
    except Exception:
        sys.stderr.buffer.write(_error_payload("supervisor.internal_error", "unexpected supervisor failure", None if request is None else request.request_id))
        return 70


if __name__ == "__main__":
    raise SystemExit(main())
