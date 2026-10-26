"""Command-line entry point for the DCP-03 native data-flow proof."""

from __future__ import annotations

import argparse
import os
import stat
import sys
import tempfile
from pathlib import Path
from typing import Sequence

from .canonical import canonical_json_bytes, canonical_sha256
from .engine import analyze_request
from .errors import OutputWriteError, ProofError, RequestValidationError
from .request import MAX_REQUEST_BYTES, parse_request_bytes


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="macscope-dcp03-proof",
        description="Developer-only native SLEIGH exact-storage SSA and MemorySSA proof",
    )
    parser.add_argument("--input", default="-", help="request JSON path or '-' for stdin")
    parser.add_argument("--output", default="-", help="result JSON path or '-' for stdout")
    parser.add_argument("--cancel-file", default=None, help="existence-based cancellation sentinel")
    return parser


def _read_regular(path: Path) -> bytes:
    try:
        metadata = path.lstat()
    except OSError as error:
        raise RequestValidationError("input path is missing or inaccessible") from error
    if not stat.S_ISREG(metadata.st_mode):
        raise RequestValidationError("input path must be a regular file, not a symlink")
    if metadata.st_size > MAX_REQUEST_BYTES:
        raise RequestValidationError("request exceeds the fixed 2 MiB protocol bound")
    descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    with os.fdopen(descriptor, "rb") as stream:
        payload = stream.read(MAX_REQUEST_BYTES + 1)
    if len(payload) > MAX_REQUEST_BYTES:
        raise RequestValidationError("request grew beyond the fixed 2 MiB protocol bound")
    return payload


def _read_input(raw_path: str) -> bytes:
    if raw_path == "-":
        payload = sys.stdin.buffer.read(MAX_REQUEST_BYTES + 1)
        if len(payload) > MAX_REQUEST_BYTES:
            raise RequestValidationError("request exceeds the fixed 2 MiB protocol bound")
        return payload
    return _read_regular(Path(raw_path))


def _write_atomic(path: Path, payload: bytes) -> None:
    parent = path.parent if path.parent != Path("") else Path(".")
    try:
        parent_metadata = parent.lstat()
    except OSError as error:
        raise OutputWriteError("output directory is missing or inaccessible") from error
    if not stat.S_ISDIR(parent_metadata.st_mode) or stat.S_ISLNK(parent_metadata.st_mode):
        raise OutputWriteError("output directory must be an ordinary directory")
    try:
        existing = path.lstat()
    except FileNotFoundError:
        existing = None
    except OSError as error:
        raise OutputWriteError("output path is inaccessible") from error
    if existing is not None and (not stat.S_ISREG(existing.st_mode) or stat.S_ISLNK(existing.st_mode)):
        raise OutputWriteError("output path must be absent or an ordinary regular file")

    descriptor = -1
    temporary_path: str | None = None
    try:
        descriptor, temporary_path = tempfile.mkstemp(prefix=f".{path.name}.", dir=parent)
        os.fchmod(descriptor, 0o644)
        with os.fdopen(descriptor, "wb") as stream:
            descriptor = -1
            stream.write(payload)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary_path, path)
        temporary_path = None
    except OSError as error:
        raise OutputWriteError("could not write result atomically") from error
    finally:
        if descriptor >= 0:
            os.close(descriptor)
        if temporary_path is not None:
            try:
                os.unlink(temporary_path)
            except OSError:
                pass


def _write_output(raw_path: str, payload: bytes) -> None:
    if raw_path == "-":
        sys.stdout.buffer.write(payload)
        sys.stdout.buffer.flush()
    else:
        _write_atomic(Path(raw_path), payload)


def _error_payload(error: ProofError) -> bytes:
    result: dict[str, object] = {
        "schemaVersion": 1,
        "status": "error",
        "requestId": None,
        "error": {"code": error.code, "message": error.message},
    }
    result["contentHash"] = canonical_sha256(result)
    return canonical_json_bytes(result)


def main(argv: Sequence[str] | None = None) -> int:
    arguments = _parser().parse_args(argv)
    try:
        request = parse_request_bytes(_read_input(arguments.input))
        cancellation_path = None if arguments.cancel_file is None else Path(arguments.cancel_file)
        result = analyze_request(request, cancellation_path=cancellation_path)
        _write_output(arguments.output, canonical_json_bytes(result))
        return 0
    except ProofError as error:
        sys.stderr.buffer.write(_error_payload(error))
        sys.stderr.buffer.flush()
        return error.exit_code
    except Exception:
        error = ProofError("internal.error", "unexpected internal proof failure", 70)
        sys.stderr.buffer.write(_error_payload(error))
        sys.stderr.buffer.flush()
        return error.exit_code


if __name__ == "__main__":
    raise SystemExit(main())
