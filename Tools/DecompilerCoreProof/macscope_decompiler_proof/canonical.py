"""Canonical JSON and address primitives used by the proof protocol."""

from __future__ import annotations

import hashlib
import json
from typing import Any


UINT64_MAX = (1 << 64) - 1


def canonical_json_bytes(value: Any, *, trailing_newline: bool = True) -> bytes:
    """Serialize a JSON-compatible value with a byte-stable representation."""

    payload = json.dumps(
        value,
        ensure_ascii=False,
        allow_nan=False,
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")
    return payload + (b"\n" if trailing_newline else b"")


def canonical_sha256(value: Any) -> str:
    return hashlib.sha256(canonical_json_bytes(value, trailing_newline=False)).hexdigest()


def bytes_sha256(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


def format_address(value: int) -> str:
    if type(value) is not int or not 0 <= value <= UINT64_MAX:
        raise ValueError("address is outside unsigned 64-bit range")
    return f"0x{value:x}"


def parse_address(value: Any, label: str) -> int:
    if not isinstance(value, str):
        raise ValueError(f"{label} must be a lowercase hexadecimal address string")
    if value == "0x0":
        return 0
    if not value.startswith("0x") or len(value) < 3:
        raise ValueError(f"{label} must be a lowercase hexadecimal address string")
    digits = value[2:]
    if digits.startswith("0") or any(character not in "0123456789abcdef" for character in digits):
        raise ValueError(f"{label} must be canonical lowercase hexadecimal")
    parsed = int(digits, 16)
    if parsed > UINT64_MAX:
        raise ValueError(f"{label} exceeds unsigned 64-bit range")
    return parsed


def checked_add_address(base: int, amount: int, label: str) -> int:
    if type(amount) is not int or amount < 0:
        raise ValueError(f"{label} length must be a non-negative integer")
    result = base + amount
    if result > UINT64_MAX:
        raise ValueError(f"{label} range overflows unsigned 64-bit address space")
    return result
