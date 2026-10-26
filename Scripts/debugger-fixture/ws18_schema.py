#!/usr/bin/env python3
"""Frozen aggregate schema and canonical report encoding for WS-18.

This module is deliberately independent of the candidate runners and validator.
It owns the byte-level input and output contract shared by both.
"""

from __future__ import annotations

import hashlib
import json
import math
import os
import copy
from pathlib import Path
from typing import Any, Iterable, Mapping, Sequence


SCHEMA_ID = "macscope.ws18.debugger-transport-report.v1"
CANONICALIZATION_VERSION = 1
CANDIDATE_CONTRACT_VERSION = 1

CANDIDATE_ORDER = (
    "xcode-lldb-dap",
    "xcode-lldb-python-json",
    "macscope-lldb-cli-baseline",
)

# This is the complete matrix frozen by design section 5.3.  List and hit
# operations are intentionally distinct from their select/count counterparts.
OPERATION_ORDER = (
    "configuredLaunch",
    "launchArguments",
    "launchEnvironment",
    "launchWorkingDirectory",
    "initialBreakpoint",
    "attach",
    "detach",
    "terminate",
    "pause",
    "continue",
    "refresh",
    "runToCursor",
    "breakpointCreation",
    "breakpointHit",
    "breakpointDelete",
    "breakpointEnable",
    "breakpointDisable",
    "breakpointCondition",
    "breakpointIgnoreCount",
    "breakpointHitCount",
    "stepInto",
    "stepOver",
    "stepOut",
    "threadList",
    "threadSelection",
    "frameList",
    "frameSelection",
    "registerRead",
    "registerWrite",
    "memoryRead",
    "memoryWrite",
    "expressionEvaluation",
    "moduleList",
    "moduleLoad",
    "moduleUnload",
    "expectedExit",
    "cancelBeforeSpawn",
    "cancelInFlight",
    "timeoutRecovery",
    "adapterCrashRecovery",
)

TOP_LEVEL_KEYS = frozenset(
    {
        "schema",
        "canonicalizationVersion",
        "candidateContractVersion",
        "toolchain",
        "fixture",
        "normalization",
        "candidates",
        "validator",
    }
)
CANDIDATE_KEYS = frozenset({"candidate", "candidateVersion", "discovery", "runs"})
NORMALIZATION_KEYS = frozenset({"pathAliases", "diagnosticPreviewBytes"})
PATH_ALIAS_KEYS = frozenset({"alias", "path"})
VALIDATOR_KEYS = frozenset({"name", "contractVersion", "canonicalDigest"})
VALIDATOR_NAME = "validate_ws18.py"
VALIDATOR_CONTRACT_VERSION = 1
ZERO_SHA256 = "0" * 64

DEFAULT_DIAGNOSTIC_PREVIEW_BYTES = 1024
MAX_INPUT_BYTES = 16 * 1024 * 1024
MAX_DEPTH = 64
MAX_COLLECTION_ITEMS = 100_000
MAX_STRING_BYTES = 1024 * 1024
MAX_ABSOLUTE_NUMBER = 10**100
MIN_INTEGER = -(2**63)
MAX_INTEGER = 2**63 - 1

_INTEGER_VOLATILE_KEYS = frozenset(
    {
        "pid",
        "targetPID",
        "adapterPID",
        "helperPID",
        "debugserverPID",
        "parentPID",
        "processGroup",
        "processGroupID",
        "sessionProcessID",
        "requestSeq",
        "request_seq",
        "responseSeq",
        "seq",
    }
)
_STRING_VOLATILE_KEYS = frozenset(
    {
        "requestID",
        "requestId",
        "transportRequestID",
        "sessionID",
        "sessionId",
        "sessionToken",
        "nonce",
        "runID",
    }
)
_TIME_KEYS = frozenset(
    {
        "timestamp",
        "timestampNS",
        "wallTime",
        "monotonicTime",
        "startedAt",
        "endedAt",
        "startTimeNS",
        "deadline",
        "duration",
        "durationNS",
        "elapsed",
        "elapsedNS",
    }
)
_PATH_KEYS = frozenset(
    {
        "path",
        "canonicalPath",
        "executablePath",
        "fixturePath",
        "developerDirectory",
        "sdkPath",
        "buildRoot",
        "temporaryRoot",
        "derivedDataRoot",
    }
)

_INTEGER_VOLATILE_CATEGORY = {
    "pid": "pid",
    "targetPID": "pid",
    "adapterPID": "pid",
    "helperPID": "pid",
    "debugserverPID": "pid",
    "parentPID": "pid",
    "processGroup": "process-group",
    "processGroupID": "process-group",
    "sessionProcessID": "process-session",
    "requestSeq": "request-sequence",
    "request_seq": "request-sequence",
    "responseSeq": "response-sequence",
    "seq": "protocol-sequence",
}
_STRING_VOLATILE_CATEGORY = {
    "requestID": "request-id",
    "requestId": "request-id",
    "transportRequestID": "request-id",
    "sessionID": "session-token",
    "sessionId": "session-token",
    "sessionToken": "session-token",
    "nonce": "nonce",
    "runID": "run-id",
}


class SchemaError(ValueError):
    """The report is not a member of the frozen WS-18 machine contract."""


def _reject_constant(value: str) -> None:
    raise SchemaError("non-finite JSON number is forbidden: {0}".format(value))


def _pairs_to_object(pairs: list[tuple[str, object]]) -> dict[str, object]:
    result: dict[str, object] = {}
    for key, value in pairs:
        if key in result:
            raise SchemaError("duplicate JSON object key: {0}".format(key))
        result[key] = value
    return result


def strict_json_loads(data: bytes | str, *, max_bytes: int = MAX_INPUT_BYTES) -> object:
    """Load JSON with duplicate, non-finite, size, depth, and value bounds."""

    if not isinstance(max_bytes, int) or isinstance(max_bytes, bool) or max_bytes <= 0:
        raise ValueError("max_bytes must be a positive integer")
    if isinstance(data, bytes):
        raw = data
        try:
            text = data.decode("utf-8")
        except UnicodeDecodeError as error:
            raise SchemaError("JSON input must be UTF-8") from error
    elif isinstance(data, str):
        text = data
        raw = data.encode("utf-8")
    else:
        raise TypeError("JSON input must be bytes or str")
    if len(raw) > max_bytes:
        raise SchemaError("JSON input exceeds configured byte limit")
    try:
        value = json.loads(
            text,
            object_pairs_hook=_pairs_to_object,
            parse_constant=_reject_constant,
        )
    except SchemaError:
        raise
    except (json.JSONDecodeError, RecursionError) as error:
        raise SchemaError("invalid JSON input") from error
    _validate_value_bounds(value, "$", 0, [0])
    return value


def load_aggregate(path: str | os.PathLike[str]) -> dict[str, object]:
    source = Path(path)
    try:
        payload = strict_json_loads(source.read_bytes())
    except OSError as error:
        raise SchemaError("cannot read aggregate report: {0}".format(source)) from error
    return validate_aggregate(payload)


def _validate_value_bounds(value: object, location: str, depth: int, count: list[int]) -> None:
    if depth > MAX_DEPTH:
        raise SchemaError("{0} exceeds maximum nesting depth".format(location))
    if value is None or isinstance(value, bool):
        return
    if isinstance(value, int):
        if value < MIN_INTEGER or value > MAX_INTEGER:
            raise SchemaError("{0} integer is outside signed 64-bit bounds".format(location))
        return
    if isinstance(value, float):
        if not math.isfinite(value) or abs(value) > MAX_ABSOLUTE_NUMBER:
            raise SchemaError("{0} number is outside finite bounds".format(location))
        return
    if isinstance(value, str):
        if len(value.encode("utf-8")) > MAX_STRING_BYTES:
            raise SchemaError("{0} string exceeds configured byte limit".format(location))
        return
    if isinstance(value, list):
        count[0] += len(value)
        if count[0] > MAX_COLLECTION_ITEMS:
            raise SchemaError("JSON input has too many collection items")
        for index, item in enumerate(value):
            _validate_value_bounds(item, "{0}[{1}]".format(location, index), depth + 1, count)
        return
    if isinstance(value, dict):
        count[0] += len(value)
        if count[0] > MAX_COLLECTION_ITEMS:
            raise SchemaError("JSON input has too many collection items")
        for key, item in value.items():
            if not isinstance(key, str):
                raise SchemaError("{0} contains a non-string key".format(location))
            _validate_value_bounds(item, "{0}.{1}".format(location, key), depth + 1, count)
        return
    raise SchemaError("{0} contains an unsupported JSON value".format(location))


def make_normalization(
    path_aliases: Sequence[Mapping[str, str]] = (),
    *,
    diagnostic_preview_bytes: int = DEFAULT_DIAGNOSTIC_PREVIEW_BYTES,
) -> dict[str, object]:
    return {
        "pathAliases": [dict(item) for item in path_aliases],
        "diagnosticPreviewBytes": diagnostic_preview_bytes,
    }


def make_candidate(
    candidate: str,
    candidate_version: str,
    discovery: Mapping[str, object],
    runs: Sequence[Mapping[str, object]],
) -> dict[str, object]:
    return {
        "candidate": candidate,
        "candidateVersion": candidate_version,
        "discovery": dict(discovery),
        "runs": [dict(run) for run in runs],
    }


def make_validator_envelope(canonical_digest: str = ZERO_SHA256) -> dict[str, object]:
    return {
        "name": VALIDATOR_NAME,
        "contractVersion": VALIDATOR_CONTRACT_VERSION,
        "canonicalDigest": canonical_digest,
    }


def make_aggregate(
    *,
    toolchain: Mapping[str, object],
    fixture: Mapping[str, object],
    normalization: Mapping[str, object],
    candidates: Sequence[Mapping[str, object]],
    validator: Mapping[str, object],
) -> dict[str, object]:
    aggregate: dict[str, object] = {
        "schema": SCHEMA_ID,
        "canonicalizationVersion": CANONICALIZATION_VERSION,
        "candidateContractVersion": CANDIDATE_CONTRACT_VERSION,
        "toolchain": dict(toolchain),
        "fixture": dict(fixture),
        "normalization": dict(normalization),
        "candidates": [dict(candidate) for candidate in candidates],
        "validator": dict(validator),
    }
    return validate_aggregate(aggregate)


def _require_exact_keys(value: Mapping[str, object], expected: frozenset[str], location: str) -> None:
    actual = frozenset(value)
    if actual != expected:
        missing = sorted(expected - actual)
        unknown = sorted(actual - expected)
        raise SchemaError(
            "{0} keys differ from schema (missing={1}, unknown={2})".format(
                location, missing, unknown
            )
        )


def _require_mapping(value: object, location: str) -> dict[str, object]:
    if not isinstance(value, dict):
        raise SchemaError("{0} must be a JSON object".format(location))
    return value


def _validated_aliases(normalization: Mapping[str, object]) -> list[tuple[str, str]]:
    raw_aliases = normalization["pathAliases"]
    if not isinstance(raw_aliases, list):
        raise SchemaError("$.normalization.pathAliases must be an array")
    aliases: list[tuple[str, str]] = []
    seen_aliases: set[str] = set()
    seen_paths: set[str] = set()
    for index, item in enumerate(raw_aliases):
        row = _require_mapping(item, "$.normalization.pathAliases[{0}]".format(index))
        _require_exact_keys(row, PATH_ALIAS_KEYS, "$.normalization.pathAliases[{0}]".format(index))
        alias = row["alias"]
        path = row["path"]
        if not isinstance(alias, str) or not alias.startswith("$") or "/" in alias or not alias[1:]:
            raise SchemaError("path alias must be a nonempty $NAME token")
        if not isinstance(path, str) or not os.path.isabs(path):
            raise SchemaError("path alias source must be absolute")
        canonical = os.path.realpath(path)
        if alias in seen_aliases or canonical in seen_paths:
            raise SchemaError("path aliases and canonical source paths must be unique")
        seen_aliases.add(alias)
        seen_paths.add(canonical)
        aliases.append((canonical, alias))
    aliases.sort(key=lambda item: (-len(item[0]), item[0], item[1]))
    return aliases


def validate_aggregate(value: object) -> dict[str, object]:
    """Validate aggregate shape and frozen ordering, returning the same object."""

    aggregate = _require_mapping(value, "$")
    _validate_value_bounds(aggregate, "$", 0, [0])
    _require_exact_keys(aggregate, TOP_LEVEL_KEYS, "$")
    if aggregate["schema"] != SCHEMA_ID:
        raise SchemaError("$.schema does not identify the WS-18 v1 contract")
    if aggregate["canonicalizationVersion"] != CANONICALIZATION_VERSION:
        raise SchemaError("unsupported canonicalizationVersion")
    if aggregate["candidateContractVersion"] != CANDIDATE_CONTRACT_VERSION:
        raise SchemaError("unsupported candidateContractVersion")
    for key in ("toolchain", "fixture", "validator"):
        _require_mapping(aggregate[key], "$.{0}".format(key))

    validator = _require_mapping(aggregate["validator"], "$.validator")
    _require_exact_keys(validator, VALIDATOR_KEYS, "$.validator")
    if validator["name"] != VALIDATOR_NAME:
        raise SchemaError("$.validator.name does not identify the frozen validator")
    if validator["contractVersion"] != VALIDATOR_CONTRACT_VERSION:
        raise SchemaError("unsupported validator contractVersion")
    validator_digest_value = validator["canonicalDigest"]
    if (
        not isinstance(validator_digest_value, str)
        or len(validator_digest_value) != 64
        or any(character not in "0123456789abcdef" for character in validator_digest_value)
    ):
        raise SchemaError("$.validator.canonicalDigest must be 64 lowercase hexadecimal characters")

    normalization = _require_mapping(aggregate["normalization"], "$.normalization")
    _require_exact_keys(normalization, NORMALIZATION_KEYS, "$.normalization")
    preview_bytes = normalization["diagnosticPreviewBytes"]
    if (
        not isinstance(preview_bytes, int)
        or isinstance(preview_bytes, bool)
        or preview_bytes <= 0
        or preview_bytes > MAX_STRING_BYTES
    ):
        raise SchemaError("diagnosticPreviewBytes must be a bounded positive integer")
    _validated_aliases(normalization)

    candidates = aggregate["candidates"]
    if not isinstance(candidates, list):
        raise SchemaError("$.candidates must be an array")
    identifiers: list[str] = []
    for index, item in enumerate(candidates):
        candidate = _require_mapping(item, "$.candidates[{0}]".format(index))
        _require_exact_keys(candidate, CANDIDATE_KEYS, "$.candidates[{0}]".format(index))
        identifier = candidate["candidate"]
        version = candidate["candidateVersion"]
        if not isinstance(identifier, str):
            raise SchemaError("candidate identifier must be a string")
        if not isinstance(version, str) or not version:
            raise SchemaError("candidateVersion must be a nonempty string")
        _require_mapping(candidate["discovery"], "$.candidates[{0}].discovery".format(index))
        runs = candidate["runs"]
        if not isinstance(runs, list):
            raise SchemaError("candidate runs must be an array")
        for run_index, run_value in enumerate(runs):
            run = _require_mapping(
                run_value, "$.candidates[{0}].runs[{1}]".format(index, run_index)
            )
            if "operations" in run:
                _validate_operations(run["operations"], index, run_index)
        identifiers.append(identifier)
    if tuple(identifiers) != CANDIDATE_ORDER:
        raise SchemaError("candidate identifiers must appear exactly once in frozen order")
    return aggregate


def _validate_operations(value: object, candidate_index: int, run_index: int) -> None:
    if not isinstance(value, list):
        raise SchemaError("run operations must be an array")
    names: list[str] = []
    for operation_index, operation_value in enumerate(value):
        operation = _require_mapping(
            operation_value,
            "$.candidates[{0}].runs[{1}].operations[{2}]".format(
                candidate_index, run_index, operation_index
            ),
        )
        name = operation.get("name")
        if not isinstance(name, str):
            raise SchemaError("every operation row requires a string name")
        names.append(name)
    if tuple(names) != OPERATION_ORDER:
        raise SchemaError("operation rows must appear exactly once in frozen order")


def _path_alias(value: str, aliases: Sequence[tuple[str, str]]) -> str:
    canonical = os.path.realpath(value)
    for source, alias in aliases:
        if canonical == source:
            return alias
        boundary = source if source == os.sep else source + os.sep
        if canonical.startswith(boundary):
            suffix = canonical[len(source) :]
            return alias + suffix
    return canonical


def _diagnostic_projection(value: str, preview_bytes: int) -> dict[str, object]:
    encoded = value.encode("utf-8")
    preview = encoded[:preview_bytes].decode("utf-8", errors="ignore")
    return {
        "preview": preview,
        "sha256": hashlib.sha256(encoded).hexdigest(),
        "byteCount": len(encoded),
    }


def _is_time_key(key: str | None, suffixes: tuple[str, ...]) -> bool:
    return key in _TIME_KEYS or (key is not None and key.endswith(suffixes))


class _Canonicalizer:
    def __init__(self, aliases: Sequence[tuple[str, str]], diagnostic_preview_bytes: int):
        self.aliases = aliases
        self.diagnostic_preview_bytes = diagnostic_preview_bytes
        self.volatile_aliases: dict[tuple[str, type, object], str] = {}
        self.volatile_counts: dict[str, int] = {}

    def project(self, value: object, key: str | None = None) -> object:
        if isinstance(value, dict):
            # The alias declaration records the semantic token, not a host root.
            if key == "normalization":
                result = {
                    item_key: self.project(value[item_key], item_key)
                    for item_key in sorted(value)
                }
                raw_aliases = value.get("pathAliases")
                if isinstance(raw_aliases, list):
                    result["pathAliases"] = [
                        {"alias": alias, "path": alias}
                        for _, alias in sorted(self.aliases, key=lambda item: item[1])
                    ]
                return result
            return {
                item_key: self.project(value[item_key], item_key)
                for item_key in sorted(value)
            }
        if isinstance(value, list):
            if key in {"diagnostics", "diagnostic"}:
                return [
                    _diagnostic_projection(item, self.diagnostic_preview_bytes)
                    if isinstance(item, str)
                    else self.project(item)
                    for item in value
                ]
            return [self.project(item, key) for item in value]
        if isinstance(value, str):
            if key in {"diagnostic", "stderr", "stdout"}:
                return _diagnostic_projection(value, self.diagnostic_preview_bytes)
            if key in _PATH_KEYS or (key is not None and key.endswith("Path")):
                return _path_alias(value, self.aliases)
            if key in _STRING_VOLATILE_KEYS:
                return self._volatile(value, _STRING_VOLATILE_CATEGORY[key])
            return value
        if isinstance(value, int) and not isinstance(value, bool):
            if key in _INTEGER_VOLATILE_KEYS:
                return self._volatile(value, _INTEGER_VOLATILE_CATEGORY[key])
            if _is_time_key(key, ("Timestamp", "TimeNS")):
                return "<time>"
            return value
        if isinstance(value, float):
            if _is_time_key(key, ("Timestamp", "Duration")):
                return "<time>"
            return value
        return value

    def _volatile(self, value: object, category: str) -> str:
        identity = (category, type(value), value)
        existing = self.volatile_aliases.get(identity)
        if existing is not None:
            return existing
        count = self.volatile_counts.get(category, 0) + 1
        self.volatile_counts[category] = count
        alias = "<{0}:{1}>".format(category, count)
        self.volatile_aliases[identity] = alias
        return alias


def canonical_document(aggregate: object) -> dict[str, object]:
    validated = validate_aggregate(aggregate)
    normalization = validated["normalization"]
    assert isinstance(normalization, dict)
    aliases = _validated_aliases(normalization)
    preview_bytes = normalization["diagnosticPreviewBytes"]
    assert isinstance(preview_bytes, int)
    projected = _Canonicalizer(aliases, preview_bytes).project(validated)
    assert isinstance(projected, dict)
    return projected


def canonical_bytes(aggregate: object) -> bytes:
    payload = json.dumps(
        canonical_document(aggregate),
        ensure_ascii=False,
        allow_nan=False,
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")
    return payload + b"\n"


def canonical_digest(aggregate: object) -> str:
    return hashlib.sha256(canonical_bytes(aggregate)).hexdigest()


def validator_digest(aggregate: object) -> str:
    """Digest the canonical report with the circular validator field zeroed."""

    validated = validate_aggregate(aggregate)
    projection = copy.deepcopy(validated)
    validator = projection["validator"]
    assert isinstance(validator, dict)
    validator["canonicalDigest"] = ZERO_SHA256
    return hashlib.sha256(canonical_bytes(projection)).hexdigest()


def seal_validator_digest(aggregate: object) -> dict[str, object]:
    """Return an independent aggregate carrying its computed validator digest."""

    validated = validate_aggregate(aggregate)
    sealed = copy.deepcopy(validated)
    validator = sealed["validator"]
    assert isinstance(validator, dict)
    validator["canonicalDigest"] = validator_digest(sealed)
    return validate_aggregate(sealed)


def validator_digest_matches(aggregate: object) -> bool:
    validated = validate_aggregate(aggregate)
    validator = validated["validator"]
    assert isinstance(validator, dict)
    return validator["canonicalDigest"] == validator_digest(validated)


def write_canonical(path: str | os.PathLike[str], aggregate: object) -> str:
    payload = canonical_bytes(aggregate)
    Path(path).write_bytes(payload)
    return hashlib.sha256(payload).hexdigest()


__all__ = [
    "SCHEMA_ID",
    "CANONICALIZATION_VERSION",
    "CANDIDATE_CONTRACT_VERSION",
    "CANDIDATE_ORDER",
    "OPERATION_ORDER",
    "SchemaError",
    "strict_json_loads",
    "load_aggregate",
    "make_normalization",
    "make_candidate",
    "make_validator_envelope",
    "make_aggregate",
    "validate_aggregate",
    "canonical_document",
    "canonical_bytes",
    "canonical_digest",
    "validator_digest",
    "seal_validator_digest",
    "validator_digest_matches",
    "write_canonical",
]
