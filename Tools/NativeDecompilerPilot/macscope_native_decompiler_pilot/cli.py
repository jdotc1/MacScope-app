"""Child-process entry point for the DCP-03B3 libghidra pilot."""

from __future__ import annotations

import argparse
import json
import os
import stat
import sys
import tempfile
from pathlib import Path
from typing import Sequence

from macscope_decompiler_proof.canonical import canonical_json_bytes, canonical_sha256
from macscope_decompiler_proof.errors import ProofError, RequestValidationError
from macscope_decompiler_proof.request import MAX_REQUEST_BYTES, parse_request_bytes

from .carrier import build_macho_carrier
from .errors import CancelledError, PilotError
from .normalize import build_result
from .provider import LibGhidraExtensionProvider
from .result_validation import validate_result


def parser() -> argparse.ArgumentParser:
    value = argparse.ArgumentParser(description="Run the isolated DCP-03B3 native decompiler pilot")
    value.add_argument("--input", default="-")
    value.add_argument("--output", default="-")
    value.add_argument("--materialization", required=True)
    value.add_argument("--cancel-file", default=None)
    return value


def _read_regular(path: Path) -> bytes:
    try:
        before = path.lstat()
    except OSError as error:
        raise RequestValidationError("input path is missing or inaccessible") from error
    if not stat.S_ISREG(before.st_mode) or stat.S_ISLNK(before.st_mode):
        raise RequestValidationError("input path must be an ordinary regular file")
    if before.st_size > MAX_REQUEST_BYTES:
        raise RequestValidationError("request exceeds the fixed 2 MiB protocol bound")
    descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    with os.fdopen(descriptor, "rb") as stream:
        payload = stream.read(MAX_REQUEST_BYTES + 1)
    if len(payload) > MAX_REQUEST_BYTES:
        raise RequestValidationError("request grew beyond the fixed protocol bound")
    return payload


def _read_input(value: str) -> bytes:
    if value == "-":
        payload = sys.stdin.buffer.read(MAX_REQUEST_BYTES + 1)
        if len(payload) > MAX_REQUEST_BYTES:
            raise RequestValidationError("request exceeds the fixed protocol bound")
        return payload
    return _read_regular(Path(value))


def _write_atomic(path: Path, payload: bytes) -> None:
    parent = path.parent if path.parent != Path("") else Path(".")
    metadata = parent.lstat()
    if not stat.S_ISDIR(metadata.st_mode) or stat.S_ISLNK(metadata.st_mode):
        raise PilotError("output.write_failed", "output directory must be ordinary", 7)
    try:
        existing = path.lstat()
    except FileNotFoundError:
        existing = None
    if existing is not None and (not stat.S_ISREG(existing.st_mode) or stat.S_ISLNK(existing.st_mode)):
        raise PilotError("output.write_failed", "output path must be absent or ordinary", 7)
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
        raise PilotError("output.write_failed", "result could not be written atomically", 7) from error
    finally:
        if descriptor >= 0:
            os.close(descriptor)
        if temporary is not None:
            try:
                os.unlink(temporary)
            except OSError:
                pass


def _write_output(path: str, payload: bytes) -> None:
    if path == "-":
        sys.stdout.buffer.write(payload)
        sys.stdout.buffer.flush()
    else:
        _write_atomic(Path(path), payload)


def _cancelled(path: Path | None) -> bool:
    if path is None:
        return False
    try:
        path.lstat()
    except FileNotFoundError:
        return False
    except OSError:
        return True
    return True


def _error_payload(code: str, message: str, request_id: str | None) -> bytes:
    value: dict[str, object] = {
        "schemaVersion": 1,
        "status": "error",
        "requestId": request_id,
        "error": {"code": code, "message": message},
    }
    value["contentHash"] = canonical_sha256(value)
    return canonical_json_bytes(value)


def main(argv: Sequence[str] | None = None) -> int:
    arguments = parser().parse_args(argv)
    request = None
    try:
        request = parse_request_bytes(_read_input(arguments.input))
        cancellation_path = None if arguments.cancel_file is None else Path(arguments.cancel_file)
        if _cancelled(cancellation_path):
            raise CancelledError()
        carrier = build_macho_carrier(request)
        with tempfile.TemporaryDirectory(prefix="macscope-dcp03b3-") as directory:
            root = Path(directory)
            carrier_path = root / "carrier.macho"
            state_directory = root / "state"
            state_directory.mkdir(mode=0o700)
            carrier.write(carrier_path)
            provider = LibGhidraExtensionProvider(Path(arguments.materialization))
            output = provider.decompile(
                request=request,
                carrier=carrier,
                carrier_path=carrier_path,
                state_directory=state_directory,
                cancellation_path=cancellation_path,
            )
        if _cancelled(cancellation_path):
            raise CancelledError()
        result = build_result(request=request, carrier=carrier, output=output)
        validate_result(result, request=request)
        _write_output(arguments.output, canonical_json_bytes(result))
        return 0
    except (PilotError, ProofError) as error:
        sys.stderr.buffer.write(
            _error_payload(error.code, error.message, None if request is None else request.request_id)
        )
        sys.stderr.buffer.flush()
        return error.exit_code
    except Exception:
        sys.stderr.buffer.write(
            _error_payload(
                "internal.error",
                "unexpected native decompiler pilot failure",
                None if request is None else request.request_id,
            )
        )
        sys.stderr.buffer.flush()
        return 70


if __name__ == "__main__":
    raise SystemExit(main())
