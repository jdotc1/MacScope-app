"""Fail-closed request parser for the DCP-03 native SLEIGH proof protocol."""

from __future__ import annotations

import json
import re
from dataclasses import dataclass
from typing import Any

from .canonical import (
    UINT64_MAX,
    bytes_sha256,
    canonical_json_bytes,
    checked_add_address,
    format_address,
    parse_address,
)
from .contract import ENGINE_LANGUAGE_ALLOWLIST
from .errors import RequestValidationError

SCHEMA_VERSION = 1
MAX_REQUEST_BYTES = 2 * 1024 * 1024
MAX_REGION_BYTES = 1024 * 1024
MAX_REGIONS = 256
MAX_SYMBOLS = 100_000
MAX_AUXILIARY_RECORDS = 100_000
MAX_TEXT = 512
LANGUAGE_ALLOWLIST = ENGINE_LANGUAGE_ALLOWLIST

_TOP_KEYS = {
    "schemaVersion",
    "requestId",
    "engine",
    "image",
    "function",
    "memoryRegions",
    "symbols",
    "relocations",
    "fixups",
    "typeHints",
    "budgets",
}
_ENGINE_KEYS = {"languageId", "compilerSpecId"}
_IMAGE_KEYS = {"imageId", "uuid", "preferredLoadAddress"}
_FUNCTION_KEYS = {"functionId", "name", "entryAddress", "endAddressExclusive"}
_REGION_KEYS = {"name", "startAddress", "permissions", "bytesHex"}
_SYMBOL_KEYS = {"imageId", "address", "name", "kind"}
_RELOCATION_KEYS = {"address", "kind", "targetAddress", "symbol", "addend"}
_FIXUP_KEYS = {"address", "kind", "targetAddress", "authenticated", "key", "diversity"}
_TYPE_HINT_KEYS = {"subjectKind", "address", "typeName", "confidence", "source"}
_BUDGET_KEYS = {
    "maxCodeBytes",
    "maxInstructions",
    "maxPcodeOps",
    "maxOutputBytes",
    "maxWallTimeMs",
}
_IDENTIFIER = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:-]{0,255}$")
_UUID = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
_PERMISSIONS = re.compile(r"^[r-][w-][x-]$")


class _DuplicateKey(ValueError):
    pass


def _without_duplicate_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise _DuplicateKey(key)
        result[key] = value
    return result


def _exact_object(value: Any, keys: set[str], label: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise RequestValidationError(f"{label} must be an object")
    missing = sorted(keys - set(value))
    unknown = sorted(set(value) - keys)
    if missing:
        raise RequestValidationError(f"{label} is missing keys: {', '.join(missing)}")
    if unknown:
        raise RequestValidationError(f"{label} has unknown keys: {', '.join(unknown)}")
    return value


def _has_disallowed_text(value: str) -> bool:
    return any(
        ord(character) < 0x20
        or 0x7F <= ord(character) <= 0x9F
        or 0xD800 <= ord(character) <= 0xDFFF
        for character in value
    )


def _text(value: Any, label: str, *, maximum: int = MAX_TEXT, allow_empty: bool = False) -> str:
    if not isinstance(value, str) or len(value) > maximum or (not value and not allow_empty):
        qualifier = "bounded text" if allow_empty else "non-empty bounded text"
        raise RequestValidationError(f"{label} must be {qualifier}")
    if _has_disallowed_text(value):
        raise RequestValidationError(f"{label} contains unsupported control or surrogate text")
    return value


def _identifier(value: Any, label: str) -> str:
    text = _text(value, label, maximum=256)
    if _IDENTIFIER.fullmatch(text) is None:
        raise RequestValidationError(f"{label} is not a canonical identifier")
    return text


def _integer(value: Any, label: str, *, minimum: int, maximum: int) -> int:
    if type(value) is not int or not minimum <= value <= maximum:
        raise RequestValidationError(f"{label} must be an integer in {minimum}...{maximum}")
    return value


def _address(value: Any, label: str) -> int:
    try:
        return parse_address(value, label)
    except ValueError as error:
        raise RequestValidationError(str(error)) from error


def _nullable_address(value: Any, label: str) -> int | None:
    return None if value is None else _address(value, label)


def _hex_bytes(value: Any, label: str) -> bytes:
    text = _text(value, label, maximum=MAX_REGION_BYTES * 2, allow_empty=True)
    if len(text) % 2 != 0 or any(character not in "0123456789abcdef" for character in text):
        raise RequestValidationError(f"{label} must be even-length lowercase hexadecimal")
    return bytes.fromhex(text)


@dataclass(frozen=True)
class Budget:
    max_code_bytes: int
    max_instructions: int
    max_pcode_ops: int
    max_output_bytes: int
    max_wall_time_ms: int


@dataclass(frozen=True)
class MemoryRegion:
    name: str
    start: int
    permissions: str
    data: bytes

    @property
    def end(self) -> int:
        return self.start + len(self.data)

    def output(self) -> dict[str, object]:
        return {
            "name": self.name,
            "startAddress": format_address(self.start),
            "endAddressExclusive": format_address(self.end),
            "permissions": self.permissions,
            "byteCount": len(self.data),
            "sha256": bytes_sha256(self.data),
        }


@dataclass(frozen=True)
class Symbol:
    image_id: str
    address: int
    name: str
    kind: str

    def output(self) -> dict[str, object]:
        return {
            "imageId": self.image_id,
            "address": format_address(self.address),
            "name": self.name,
            "kind": self.kind,
        }


@dataclass(frozen=True)
class Relocation:
    address: int
    kind: str
    target_address: int | None
    symbol: str | None
    addend: int

    def output(self) -> dict[str, object]:
        return {
            "address": format_address(self.address),
            "kind": self.kind,
            "targetAddress": None if self.target_address is None else format_address(self.target_address),
            "symbol": self.symbol,
            "addend": self.addend,
        }


@dataclass(frozen=True)
class Fixup:
    address: int
    kind: str
    target_address: int | None
    authenticated: bool
    key: str | None
    diversity: int | None

    def output(self) -> dict[str, object]:
        return {
            "address": format_address(self.address),
            "kind": self.kind,
            "targetAddress": None if self.target_address is None else format_address(self.target_address),
            "authenticated": self.authenticated,
            "key": self.key,
            "diversity": self.diversity,
        }


@dataclass(frozen=True)
class TypeHint:
    subject_kind: str
    address: int
    type_name: str
    confidence: str
    source: str

    def output(self) -> dict[str, object]:
        return {
            "subjectKind": self.subject_kind,
            "address": format_address(self.address),
            "typeName": self.type_name,
            "confidence": self.confidence,
            "source": self.source,
        }


@dataclass(frozen=True)
class AnalysisRequest:
    request_id: str
    language_id: str
    compiler_spec_id: str
    image_id: str
    image_uuid: str
    preferred_load_address: int
    function_id: str
    function_name: str
    function_entry: int
    function_end: int
    memory_regions: tuple[MemoryRegion, ...]
    symbols: tuple[Symbol, ...]
    relocations: tuple[Relocation, ...]
    fixups: tuple[Fixup, ...]
    type_hints: tuple[TypeHint, ...]
    budgets: Budget
    canonical_input: dict[str, Any]

    @property
    def function_size(self) -> int:
        return self.function_end - self.function_entry

    @property
    def request_sha256(self) -> str:
        return bytes_sha256(canonical_json_bytes(self.canonical_input, trailing_newline=False))

    def read(self, start: int, end: int, *, require_executable: bool = False) -> bytes:
        if start < 0 or end < start or end > UINT64_MAX + 1:
            raise RequestValidationError("requested memory range is malformed")
        cursor = start
        output = bytearray()
        for region in self.memory_regions:
            if region.end <= cursor:
                continue
            if region.start > cursor:
                break
            if require_executable and region.permissions[2] != "x":
                raise RequestValidationError("function range includes non-executable memory")
            take_end = min(end, region.end)
            offset = cursor - region.start
            output.extend(region.data[offset : offset + (take_end - cursor)])
            cursor = take_end
            if cursor == end:
                return bytes(output)
        raise RequestValidationError(
            f"memory range is not fully mapped: {format_address(start)}..{format_address(end)}"
        )

    def symbol_at(self, address: int) -> Symbol | None:
        candidates = [symbol for symbol in self.symbols if symbol.address == address]
        if not candidates:
            return None
        return sorted(candidates, key=lambda item: (item.kind, item.name, item.image_id))[0]


def _parse_symbols(raw: Any, image_id: str) -> tuple[Symbol, ...]:
    if not isinstance(raw, list) or len(raw) > MAX_SYMBOLS:
        raise RequestValidationError("symbols must be a bounded array")
    result: list[Symbol] = []
    for index, item in enumerate(raw):
        value = _exact_object(item, _SYMBOL_KEYS, f"symbols[{index}]")
        symbol_image = _identifier(value["imageId"], f"symbols[{index}].imageId")
        if symbol_image != image_id:
            raise RequestValidationError(f"symbols[{index}] references a different image")
        result.append(
            Symbol(
                image_id=symbol_image,
                address=_address(value["address"], f"symbols[{index}].address"),
                name=_text(value["name"], f"symbols[{index}].name", maximum=1024),
                kind=_identifier(value["kind"], f"symbols[{index}].kind"),
            )
        )
    return tuple(sorted(result, key=lambda item: (item.address, item.kind, item.name)))


def _parse_relocations(raw: Any) -> tuple[Relocation, ...]:
    if not isinstance(raw, list) or len(raw) > MAX_AUXILIARY_RECORDS:
        raise RequestValidationError("relocations must be a bounded array")
    result: list[Relocation] = []
    for index, item in enumerate(raw):
        value = _exact_object(item, _RELOCATION_KEYS, f"relocations[{index}]")
        symbol_value = value["symbol"]
        symbol = None if symbol_value is None else _text(symbol_value, f"relocations[{index}].symbol", maximum=1024)
        result.append(
            Relocation(
                address=_address(value["address"], f"relocations[{index}].address"),
                kind=_identifier(value["kind"], f"relocations[{index}].kind"),
                target_address=_nullable_address(value["targetAddress"], f"relocations[{index}].targetAddress"),
                symbol=symbol,
                addend=_integer(value["addend"], f"relocations[{index}].addend", minimum=-(1 << 63), maximum=(1 << 63) - 1),
            )
        )
    return tuple(sorted(result, key=lambda item: (item.address, item.kind, item.addend, item.symbol or "")))


def _parse_fixups(raw: Any) -> tuple[Fixup, ...]:
    if not isinstance(raw, list) or len(raw) > MAX_AUXILIARY_RECORDS:
        raise RequestValidationError("fixups must be a bounded array")
    result: list[Fixup] = []
    for index, item in enumerate(raw):
        value = _exact_object(item, _FIXUP_KEYS, f"fixups[{index}]")
        if type(value["authenticated"]) is not bool:
            raise RequestValidationError(f"fixups[{index}].authenticated must be a boolean")
        key_value = value["key"]
        key = None if key_value is None else _identifier(key_value, f"fixups[{index}].key")
        diversity_value = value["diversity"]
        diversity = None if diversity_value is None else _integer(
            diversity_value, f"fixups[{index}].diversity", minimum=0, maximum=0xFFFF
        )
        if not value["authenticated"] and (key is not None or diversity is not None):
            raise RequestValidationError(f"fixups[{index}] has authentication fields without authentication")
        result.append(
            Fixup(
                address=_address(value["address"], f"fixups[{index}].address"),
                kind=_identifier(value["kind"], f"fixups[{index}].kind"),
                target_address=_nullable_address(value["targetAddress"], f"fixups[{index}].targetAddress"),
                authenticated=value["authenticated"],
                key=key,
                diversity=diversity,
            )
        )
    return tuple(sorted(result, key=lambda item: (item.address, item.kind)))


def _parse_type_hints(raw: Any) -> tuple[TypeHint, ...]:
    if not isinstance(raw, list) or len(raw) > MAX_AUXILIARY_RECORDS:
        raise RequestValidationError("typeHints must be a bounded array")
    result: list[TypeHint] = []
    allowed_confidence = {"asserted", "high", "medium", "low"}
    for index, item in enumerate(raw):
        value = _exact_object(item, _TYPE_HINT_KEYS, f"typeHints[{index}]")
        confidence = _identifier(value["confidence"], f"typeHints[{index}].confidence")
        if confidence not in allowed_confidence:
            raise RequestValidationError(f"typeHints[{index}].confidence is unsupported")
        result.append(
            TypeHint(
                subject_kind=_identifier(value["subjectKind"], f"typeHints[{index}].subjectKind"),
                address=_address(value["address"], f"typeHints[{index}].address"),
                type_name=_text(value["typeName"], f"typeHints[{index}].typeName", maximum=4096),
                confidence=confidence,
                source=_identifier(value["source"], f"typeHints[{index}].source"),
            )
        )
    return tuple(sorted(result, key=lambda item: (item.address, item.subject_kind, item.type_name, item.source)))


def _parse_regions(raw: Any, budget_code_bytes: int) -> tuple[MemoryRegion, ...]:
    if not isinstance(raw, list) or not 1 <= len(raw) <= MAX_REGIONS:
        raise RequestValidationError("memoryRegions must contain 1..256 records")
    result: list[MemoryRegion] = []
    total_bytes = 0
    for index, item in enumerate(raw):
        value = _exact_object(item, _REGION_KEYS, f"memoryRegions[{index}]")
        data = _hex_bytes(value["bytesHex"], f"memoryRegions[{index}].bytesHex")
        if not data:
            raise RequestValidationError(f"memoryRegions[{index}] must not be empty")
        total_bytes += len(data)
        if total_bytes > budget_code_bytes:
            raise RequestValidationError("memory region bytes exceed maxCodeBytes")
        start = _address(value["startAddress"], f"memoryRegions[{index}].startAddress")
        try:
            checked_add_address(start, len(data), f"memoryRegions[{index}]")
        except ValueError as error:
            raise RequestValidationError(str(error)) from error
        permissions = _text(value["permissions"], f"memoryRegions[{index}].permissions", maximum=3)
        if _PERMISSIONS.fullmatch(permissions) is None:
            raise RequestValidationError(f"memoryRegions[{index}].permissions must use rwx triplet syntax")
        result.append(
            MemoryRegion(
                name=_text(value["name"], f"memoryRegions[{index}].name", maximum=256),
                start=start,
                permissions=permissions,
                data=data,
            )
        )
    result.sort(key=lambda item: (item.start, item.end, item.name))
    previous_end = -1
    for region in result:
        if region.start < previous_end:
            raise RequestValidationError("memory regions overlap")
        previous_end = region.end
    return tuple(result)


def parse_request_bytes(payload: bytes) -> AnalysisRequest:
    if not isinstance(payload, bytes):
        raise RequestValidationError("request payload must be bytes")
    if len(payload) > MAX_REQUEST_BYTES:
        raise RequestValidationError("request exceeds the fixed 2 MiB protocol bound")
    try:
        decoded = json.loads(payload, object_pairs_hook=_without_duplicate_keys)
    except _DuplicateKey as error:
        raise RequestValidationError(f"request contains duplicate JSON key: {error.args[0]}") from error
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise RequestValidationError(f"request must be UTF-8 JSON: {error}") from error

    root = _exact_object(decoded, _TOP_KEYS, "request")
    if type(root["schemaVersion"]) is not int or root["schemaVersion"] != SCHEMA_VERSION:
        raise RequestValidationError(f"unsupported schemaVersion: {root['schemaVersion']!r}")

    request_id = _identifier(root["requestId"], "requestId")
    engine = _exact_object(root["engine"], _ENGINE_KEYS, "engine")
    language_id = _text(engine["languageId"], "engine.languageId", maximum=128)
    if language_id not in LANGUAGE_ALLOWLIST:
        raise RequestValidationError(f"unsupported SLEIGH language: {language_id}")
    compiler_spec_id = _identifier(engine["compilerSpecId"], "engine.compilerSpecId")

    image = _exact_object(root["image"], _IMAGE_KEYS, "image")
    image_id = _identifier(image["imageId"], "image.imageId")
    image_uuid = _text(image["uuid"], "image.uuid", maximum=36)
    if _UUID.fullmatch(image_uuid) is None:
        raise RequestValidationError("image.uuid must be a lowercase canonical UUID")
    preferred_load_address = _address(image["preferredLoadAddress"], "image.preferredLoadAddress")

    function = _exact_object(root["function"], _FUNCTION_KEYS, "function")
    function_id = _identifier(function["functionId"], "function.functionId")
    function_name = _text(function["name"], "function.name", maximum=1024)
    function_entry = _address(function["entryAddress"], "function.entryAddress")
    function_end = _address(function["endAddressExclusive"], "function.endAddressExclusive")
    if function_end <= function_entry:
        raise RequestValidationError("function range must be non-empty and increasing")
    if function_entry % 4 != 0 or function_end % 4 != 0:
        raise RequestValidationError("AArch64 function bounds must be 4-byte aligned")

    budget_value = _exact_object(root["budgets"], _BUDGET_KEYS, "budgets")
    budget = Budget(
        max_code_bytes=_integer(budget_value["maxCodeBytes"], "budgets.maxCodeBytes", minimum=4, maximum=MAX_REGION_BYTES),
        max_instructions=_integer(budget_value["maxInstructions"], "budgets.maxInstructions", minimum=1, maximum=100_000),
        max_pcode_ops=_integer(budget_value["maxPcodeOps"], "budgets.maxPcodeOps", minimum=1, maximum=2_000_000),
        max_output_bytes=_integer(budget_value["maxOutputBytes"], "budgets.maxOutputBytes", minimum=1024, maximum=64 * 1024 * 1024),
        max_wall_time_ms=_integer(budget_value["maxWallTimeMs"], "budgets.maxWallTimeMs", minimum=1, maximum=60_000),
    )
    if function_end - function_entry > budget.max_code_bytes:
        raise RequestValidationError("function byte range exceeds maxCodeBytes")

    regions = _parse_regions(root["memoryRegions"], budget.max_code_bytes)
    symbols = _parse_symbols(root["symbols"], image_id)
    relocations = _parse_relocations(root["relocations"])
    fixups = _parse_fixups(root["fixups"])
    type_hints = _parse_type_hints(root["typeHints"])

    canonical_input = {
        "schemaVersion": SCHEMA_VERSION,
        "requestId": request_id,
        "engine": {"languageId": language_id, "compilerSpecId": compiler_spec_id},
        "image": {
            "imageId": image_id,
            "uuid": image_uuid,
            "preferredLoadAddress": format_address(preferred_load_address),
        },
        "function": {
            "functionId": function_id,
            "name": function_name,
            "entryAddress": format_address(function_entry),
            "endAddressExclusive": format_address(function_end),
        },
        "memoryRegions": [
            {
                "name": region.name,
                "startAddress": format_address(region.start),
                "permissions": region.permissions,
                "bytesHex": region.data.hex(),
            }
            for region in regions
        ],
        "symbols": [item.output() for item in symbols],
        "relocations": [item.output() for item in relocations],
        "fixups": [item.output() for item in fixups],
        "typeHints": [item.output() for item in type_hints],
        "budgets": {
            "maxCodeBytes": budget.max_code_bytes,
            "maxInstructions": budget.max_instructions,
            "maxPcodeOps": budget.max_pcode_ops,
            "maxOutputBytes": budget.max_output_bytes,
            "maxWallTimeMs": budget.max_wall_time_ms,
        },
    }

    request = AnalysisRequest(
        request_id=request_id,
        language_id=language_id,
        compiler_spec_id=compiler_spec_id,
        image_id=image_id,
        image_uuid=image_uuid,
        preferred_load_address=preferred_load_address,
        function_id=function_id,
        function_name=function_name,
        function_entry=function_entry,
        function_end=function_end,
        memory_regions=regions,
        symbols=symbols,
        relocations=relocations,
        fixups=fixups,
        type_hints=type_hints,
        budgets=budget,
        canonical_input=canonical_input,
    )
    request.read(function_entry, function_end, require_executable=True)
    return request
