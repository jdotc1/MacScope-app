"""Strict canonical JSON used for every Gate F identity and receipt digest."""

from __future__ import annotations

import dataclasses
import hashlib
import json
import os
from collections.abc import Mapping
from enum import Enum
from pathlib import Path
from typing import Any

MIN_INTEGER = -(2**63)
MAX_INTEGER = 2**63 - 1


class CanonicalJSONError(ValueError):
    pass


def to_primitive(value: Any, *, path: str = "$") -> Any:
    if dataclasses.is_dataclass(value) and not isinstance(value, type):
        value = {field.name: getattr(value, field.name) for field in dataclasses.fields(value)}
    if isinstance(value, Enum):
        return to_primitive(value.value, path=path)
    if value is None or isinstance(value, (str, bool)):
        return value
    if isinstance(value, int):
        if not MIN_INTEGER <= value <= MAX_INTEGER:
            raise CanonicalJSONError(f"{path}: integer is outside signed 64-bit bounds")
        return value
    if isinstance(value, float):
        raise CanonicalJSONError(f"{path}: floating-point values are forbidden")
    if isinstance(value, Mapping):
        normalized: dict[str, Any] = {}
        for key, child in value.items():
            if not isinstance(key, str):
                raise CanonicalJSONError(f"{path}: object keys must be strings")
            normalized[key] = to_primitive(child, path=f"{path}.{key}")
        return normalized
    if isinstance(value, (list, tuple)):
        return [to_primitive(child, path=f"{path}[{index}]") for index, child in enumerate(value)]
    raise CanonicalJSONError(f"{path}: unsupported value type {type(value).__name__}")


def canonical_text(value: Any) -> str:
    return json.dumps(
        to_primitive(value),
        ensure_ascii=False,
        allow_nan=False,
        sort_keys=True,
        separators=(",", ":"),
    )


def canonical_bytes(value: Any) -> bytes:
    try:
        return canonical_text(value).encode("utf-8")
    except UnicodeEncodeError as error:
        raise CanonicalJSONError("string contains a non-UTF-8 scalar") from error


def canonical_sha256(value: Any) -> str:
    return hashlib.sha256(canonical_bytes(value)).hexdigest()


def _reject_float(value: str) -> None:
    raise CanonicalJSONError(f"floating-point value is forbidden: {value}")


def _parse_integer(value: str) -> int:
    parsed = int(value, 10)
    if not MIN_INTEGER <= parsed <= MAX_INTEGER:
        raise CanonicalJSONError("integer is outside signed 64-bit bounds")
    return parsed


def _closed_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise CanonicalJSONError(f"duplicate object key: {key}")
        result[key] = value
    return result


def decode_canonical_bytes(payload: bytes) -> Any:
    try:
        text = payload.decode("utf-8")
    except UnicodeDecodeError as error:
        raise CanonicalJSONError("payload is not UTF-8") from error
    try:
        value = json.loads(
            text,
            parse_float=_reject_float,
            parse_int=_parse_integer,
            parse_constant=_reject_float,
            object_pairs_hook=_closed_object,
        )
    except (json.JSONDecodeError, ValueError) as error:
        if isinstance(error, CanonicalJSONError):
            raise
        raise CanonicalJSONError(f"invalid JSON: {error}") from error
    if canonical_bytes(value) != payload:
        raise CanonicalJSONError("payload is valid JSON but not canonical JSON")
    return value


def load_canonical_json(path: Path) -> Any:
    try:
        return decode_canonical_bytes(path.read_bytes())
    except OSError as error:
        raise CanonicalJSONError(f"cannot read {path}: {error}") from error


def write_canonical_json(path: Path, value: Any) -> bool:
    payload = canonical_bytes(value)
    if path.is_file() and path.read_bytes() == payload:
        return False
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.tmp-{os.getpid()}")
    temporary.write_bytes(payload)
    os.replace(temporary, path)
    return True


def file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()
