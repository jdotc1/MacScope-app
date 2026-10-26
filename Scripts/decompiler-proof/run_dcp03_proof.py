#!/usr/bin/env python3
"""Supervise the non-shipping DCP-03 native SLEIGH data-flow proof.

The child interpreter is expected to come from the explicitly materialized
pypcode environment. This parent validates the request without importing the
native binding, enforces external resource limits, semantically validates the
complete structured response, and never runs from normal build/test entry
points.
"""

from __future__ import annotations

import argparse
import json
import math
import os
import pathlib
import re
import resource
import stat
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from typing import Any, Sequence

ROOT = pathlib.Path(__file__).resolve().parents[2]
TOOL_ROOT = ROOT / "Tools" / "DecompilerCoreProof"
sys.path.insert(0, str(TOOL_ROOT))

from macscope_decompiler_proof.canonical import canonical_json_bytes, canonical_sha256
from macscope_decompiler_proof.contract import RESULT_SCHEMA_VERSION
from macscope_decompiler_proof.errors import ProofError
from macscope_decompiler_proof.request import MAX_REQUEST_BYTES, AnalysisRequest, parse_request_bytes
from macscope_decompiler_proof.result_validation import ResultValidationError, validate_result

STARTUP_ALLOWANCE_SECONDS = 2.0
MAX_ADDRESS_SPACE_BYTES = 2 * 1024 * 1024 * 1024
MAX_OPEN_FILES = 64
MAX_CHILD_ERROR_BYTES = 64 * 1024
_ERROR_CODE = re.compile(r"^[a-z0-9][a-z0-9._-]{0,127}$")


def _has_disallowed_text(value: str) -> bool:
    return any(
        ord(character) < 0x20
        or 0x7F <= ord(character) <= 0x9F
        or 0xD800 <= ord(character) <= 0xDFFF
        for character in value
    )


@dataclass(frozen=True)
class SupervisorError(RuntimeError):
    code: str
    message: str
    exit_code: int = 2

    def __str__(self) -> str:
        return self.message


def parser() -> argparse.ArgumentParser:
    value = argparse.ArgumentParser(description="Supervise the MacScope DCP-03 data-flow proof backend")
    value.add_argument("--python", required=True, help="Python executable in the materialized pypcode environment")
    value.add_argument("--input", required=True, help="validated request JSON")
    value.add_argument("--output", required=True, help="canonical result JSON")
    value.add_argument("--cancel-file", default=None, help="optional existence-based cancellation sentinel")
    return value


def read_regular(path: pathlib.Path) -> bytes:
    try:
        before = path.lstat()
    except OSError as error:
        raise SupervisorError("supervisor.invalid_input", "input path is missing or inaccessible") from error
    if not stat.S_ISREG(before.st_mode):
        raise SupervisorError("supervisor.invalid_input", "input must be an ordinary regular file")
    if before.st_size > MAX_REQUEST_BYTES:
        raise SupervisorError("supervisor.invalid_input", "input exceeds the fixed request bound")

    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(path, flags)
    except OSError as error:
        raise SupervisorError("supervisor.invalid_input", "input could not be opened safely") from error
    try:
        after = os.fstat(descriptor)
        if not stat.S_ISREG(after.st_mode):
            raise SupervisorError("supervisor.invalid_input", "input must remain an ordinary regular file")
        if (before.st_dev, before.st_ino) != (after.st_dev, after.st_ino):
            raise SupervisorError("supervisor.invalid_input", "input changed while it was being opened")
        if after.st_size > MAX_REQUEST_BYTES:
            raise SupervisorError("supervisor.invalid_input", "input exceeds the fixed request bound")
        with os.fdopen(descriptor, "rb") as stream:
            descriptor = -1
            payload = stream.read(MAX_REQUEST_BYTES + 1)
    finally:
        if descriptor >= 0:
            os.close(descriptor)
    if len(payload) > MAX_REQUEST_BYTES:
        raise SupervisorError("supervisor.invalid_input", "input grew beyond the fixed request bound")
    return payload


def _set_limit(kind: int, soft: int, hard: int | None = None) -> None:
    try:
        _current_soft, current_hard = resource.getrlimit(kind)
        requested_hard = soft if hard is None else hard
        if current_hard != resource.RLIM_INFINITY:
            requested_hard = min(requested_hard, current_hard)
        requested_soft = min(soft, requested_hard)
        resource.setrlimit(kind, (requested_soft, requested_hard))
    except (OSError, ValueError):
        # Some macOS hosts reject selected advisory limits. The external timeout,
        # output cap, no-core rule, and child process boundary remain mandatory.
        pass


def resource_limiter(timeout_seconds: float, maximum_output: int):
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


def error_payload(code: str, message: str, request_id: str | None = None) -> bytes:
    value: dict[str, object] = {
        "schemaVersion": 1,
        "status": "error",
        "requestId": request_id,
        "error": {"code": code, "message": message},
    }
    value["contentHash"] = canonical_sha256(value)
    return canonical_json_bytes(value)


def _decode_canonical_object(payload: bytes) -> dict[str, Any] | None:
    try:
        decoded = json.loads(payload)
    except (UnicodeDecodeError, json.JSONDecodeError):
        return None
    if not isinstance(decoded, dict) or canonical_json_bytes(decoded) != payload:
        return None
    return decoded


def _valid_content_hash(value: dict[str, Any]) -> bool:
    observed = value.get("contentHash")
    if not isinstance(observed, str) or re.fullmatch(r"[0-9a-f]{64}", observed) is None:
        return False
    hashed = dict(value)
    hashed.pop("contentHash", None)
    return canonical_sha256(hashed) == observed


def _validated_child_error(payload: bytes, expected_request_id: str) -> bytes | None:
    decoded = _decode_canonical_object(payload)
    if decoded is None or set(decoded) != {
        "schemaVersion",
        "status",
        "requestId",
        "error",
        "contentHash",
    }:
        return None
    if type(decoded.get("schemaVersion")) is not int or decoded.get("schemaVersion") != 1:
        return None
    if decoded.get("status") != "error":
        return None
    if decoded.get("requestId") not in {None, expected_request_id}:
        return None
    error = decoded.get("error")
    if not isinstance(error, dict) or set(error) != {"code", "message"}:
        return None
    code = error.get("code")
    message = error.get("message")
    if not isinstance(code, str) or _ERROR_CODE.fullmatch(code) is None:
        return None
    if (
        not isinstance(message, str)
        or not 1 <= len(message) <= 2048
        or _has_disallowed_text(message)
    ):
        return None
    return payload if _valid_content_hash(decoded) else None


def _child_success_validation_error(payload: bytes, request: AnalysisRequest) -> str | None:
    decoded = _decode_canonical_object(payload)
    if decoded is None:
        return "proof child emitted invalid canonical JSON"
    # Check request binding before deep validation so a mismatched child cannot
    # obscure the authority violation behind an unrelated structural error.
    if type(decoded.get("schemaVersion")) is not int or decoded.get("schemaVersion") != RESULT_SCHEMA_VERSION:
        return "proof child emitted an unsupported schemaVersion"
    if decoded.get("status") != "ok":
        return "proof child did not emit an ok result"
    if decoded.get("requestId") != request.request_id:
        return "proof child result requestId did not match the request"
    if decoded.get("requestSha256") != request.request_sha256:
        return "proof child result requestSha256 did not match the request"
    try:
        validate_result(decoded, request=request)
    except ResultValidationError as error:
        return f"proof child result failed semantic validation: {error}"
    return None


def atomic_write(path: pathlib.Path, payload: bytes) -> None:
    parent = path.parent
    try:
        parent_metadata = parent.lstat()
    except OSError as error:
        raise SupervisorError("output.write_failed", "output directory is missing or inaccessible") from error
    if not stat.S_ISDIR(parent_metadata.st_mode) or stat.S_ISLNK(parent_metadata.st_mode):
        raise SupervisorError("output.write_failed", "output directory must be an ordinary directory")
    try:
        metadata = path.lstat()
    except FileNotFoundError:
        metadata = None
    except OSError as error:
        raise SupervisorError("output.write_failed", "output path is inaccessible") from error
    if metadata is not None and (not stat.S_ISREG(metadata.st_mode) or stat.S_ISLNK(metadata.st_mode)):
        raise SupervisorError("output.write_failed", "output must be absent or an ordinary regular file")

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
        try:
            directory_fd = os.open(parent, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
            try:
                os.fsync(directory_fd)
            finally:
                os.close(directory_fd)
        except OSError:
            pass
    except OSError as error:
        raise SupervisorError("output.write_failed", "could not write result atomically") from error
    finally:
        if descriptor >= 0:
            os.close(descriptor)
        if temporary is not None:
            try:
                os.unlink(temporary)
            except OSError:
                pass


def _validate_python(path: pathlib.Path) -> pathlib.Path:
    absolute = path.absolute()
    try:
        unresolved = absolute.lstat()
        resolved = absolute.resolve(strict=True)
        resolved_metadata = resolved.lstat()
    except OSError as error:
        raise SupervisorError(
            "supervisor.invalid_python",
            "materialized Python path is missing or inaccessible",
        ) from error
    if not (stat.S_ISREG(unresolved.st_mode) or stat.S_ISLNK(unresolved.st_mode)):
        raise SupervisorError(
            "supervisor.invalid_python",
            "materialized Python path must be a regular file or executable symlink",
        )
    if not stat.S_ISREG(resolved_metadata.st_mode) or not os.access(resolved, os.X_OK):
        raise SupervisorError(
            "supervisor.invalid_python",
            "materialized Python path must resolve to an executable regular file",
        )
    # Invoke the absolute, unresolved path. CPython virtual environments commonly
    # use a symlink in <venv>/bin; resolving that symlink before exec discards the
    # virtual-environment prefix and therefore its pinned site-packages.
    return absolute


def _cancellation_requested(path: pathlib.Path | None) -> bool:
    if path is None:
        return False
    try:
        path.lstat()
    except FileNotFoundError:
        return False
    except OSError:
        # An unreadable cancellation sentinel is not safe to ignore.
        return True
    return True


def _same_input_and_output(input_path: pathlib.Path, output_path: pathlib.Path) -> bool:
    try:
        input_resolved = input_path.resolve(strict=True)
        if output_path.exists():
            return input_resolved == output_path.resolve(strict=True)
        return input_resolved == output_path.parent.resolve(strict=True) / output_path.name
    except OSError as error:
        raise SupervisorError(
            "supervisor.invalid_configuration",
            "input or output path could not be resolved safely",
        ) from error


def main(argv: Sequence[str] | None = None) -> int:
    arguments = parser().parse_args(argv)
    request: AnalysisRequest | None = None
    try:
        input_path = pathlib.Path(arguments.input)
        output_path = pathlib.Path(arguments.output)
        python_path = pathlib.Path(arguments.python)
        payload = read_regular(input_path)
        request = parse_request_bytes(payload)
        invocation_python = _validate_python(python_path)
        if _same_input_and_output(input_path, output_path):
            raise SupervisorError(
                "supervisor.invalid_configuration",
                "input and output must be different files",
            )
        cancellation_path = (
            None
            if arguments.cancel_file is None
            else pathlib.Path(arguments.cancel_file).absolute()
        )
        if _cancellation_requested(cancellation_path):
            sys.stderr.buffer.write(
                error_payload("analysis.cancelled", "analysis cancelled", request.request_id)
            )
            return 6

        timeout_seconds = request.budgets.max_wall_time_ms / 1000.0 + STARTUP_ALLOWANCE_SECONDS
        environment = {
            "HOME": "/tmp",
            "LANG": "C.UTF-8",
            "LC_ALL": "C.UTF-8",
            "PATH": "/usr/bin:/bin",
            "PYTHONHASHSEED": "0",
            "PYTHONNOUSERSITE": "1",
            "PYTHONPATH": str(TOOL_ROOT),
            "TMPDIR": "/tmp",
        }
        command = [
            str(invocation_python),
            "-m",
            "macscope_decompiler_proof.cli",
            "--input",
            "-",
            "--output",
            "-",
        ]
        if cancellation_path is not None:
            command.extend(["--cancel-file", str(cancellation_path)])

        with tempfile.TemporaryFile() as stdout_file, tempfile.TemporaryFile() as stderr_file:
            process = subprocess.Popen(
                command,
                stdin=subprocess.PIPE,
                stdout=stdout_file,
                stderr=stderr_file,
                env=environment,
                cwd=ROOT,
                preexec_fn=resource_limiter(timeout_seconds, request.budgets.max_output_bytes),
            )
            try:
                process.communicate(payload, timeout=timeout_seconds)
            except subprocess.TimeoutExpired:
                process.kill()
                process.communicate()
                sys.stderr.buffer.write(
                    error_payload(
                        "resource.exhausted",
                        "external wall-clock limit exceeded",
                        request.request_id,
                    )
                )
                return 124
            stdout_file.seek(0)
            stdout = stdout_file.read(request.budgets.max_output_bytes + 1)
            stderr_file.seek(0)
            stderr = stderr_file.read(MAX_CHILD_ERROR_BYTES + 1)

        if len(stdout) > request.budgets.max_output_bytes:
            sys.stderr.buffer.write(
                error_payload("resource.exhausted", "child output exceeded maxOutputBytes", request.request_id)
            )
            return 125
        if len(stderr) > MAX_CHILD_ERROR_BYTES:
            sys.stderr.buffer.write(
                error_payload("child.failed", "proof child diagnostic exceeded its bound", request.request_id)
            )
            return 70
        if process.returncode != 0:
            child_error = _validated_child_error(stderr, request.request_id)
            if child_error is not None:
                sys.stderr.buffer.write(child_error)
                return process.returncode if 0 < process.returncode < 126 else 70
            sys.stderr.buffer.write(
                error_payload("child.failed", "proof child failed without a valid diagnostic", request.request_id)
            )
            return 70
        if stderr:
            sys.stderr.buffer.write(
                error_payload("child.invalid_output", "proof child emitted unexpected diagnostics", request.request_id)
            )
            return 70
        # A cancellation observed after child exit still wins because no result
        # can be published. This also avoids spending validation work on data
        # the caller has explicitly abandoned.
        if _cancellation_requested(cancellation_path):
            sys.stderr.buffer.write(
                error_payload("analysis.cancelled", "analysis cancelled", request.request_id)
            )
            return 6
        child_validation_error = _child_success_validation_error(stdout, request)
        if child_validation_error is not None:
            sys.stderr.buffer.write(
                error_payload(
                    "child.invalid_output",
                    child_validation_error,
                    request.request_id,
                )
            )
            return 70
        atomic_write(output_path, stdout)
        return 0
    except ProofError as error:
        sys.stderr.buffer.write(error_payload(error.code, error.message, None if request is None else request.request_id))
        return error.exit_code
    except SupervisorError as error:
        sys.stderr.buffer.write(error_payload(error.code, error.message, None if request is None else request.request_id))
        return error.exit_code
    except Exception:
        sys.stderr.buffer.write(
            error_payload(
                "supervisor.internal_error",
                "unexpected supervisor failure",
                None if request is None else request.request_id,
            )
        )
        return 70


if __name__ == "__main__":
    raise SystemExit(main())
