"""Independent semantic validation for DCP-03B3 child results.

The supervisor reconstructs MacScope-owned provider DTOs from the child result,
rebuilds DCP-03B2 effective memory and the deterministic carrier from the
original request, and reruns normalization. Recomputing ``contentHash`` cannot
make forged bytes, patch provenance, function records, capabilities, warnings,
or resource counts acceptable.
"""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any

from macscope_decompiler_proof.canonical import canonical_sha256, parse_address
from macscope_decompiler_proof.request import AnalysisRequest

from .carrier import build_macho_carrier
from .contract import (
    ANALYSIS_LEVEL,
    APPROVED_WHEELS,
    CONTRACT_COMPLETENESS,
    ENGINE_BACKEND_ID,
    ENGINE_COMPILER_SPEC_ID,
    ENGINE_COMPONENT_ID,
    ENGINE_GIT_REVISION,
    ENGINE_HOST_MODE,
    ENGINE_LANGUAGE_ID,
    ENGINE_SERVICE_NAME,
    ENGINE_SERVICE_VERSION,
    ENGINE_VERSION,
    MAX_CAPABILITY_COUNT,
    MAX_INSTRUCTION_COUNT,
    REQUIRED_NATIVE_CAPABILITIES,
    RESULT_SCHEMA_VERSION,
)
from .errors import PilotError
from .normalize import build_result
from .provider import (
    NativeCapability,
    NativeDecompilation,
    NativeEngineStatus,
    NativeFunction,
    NativeInstruction,
    NativeOpenProgram,
    NativeProviderOutput,
)


class ResultValidationError(PilotError):
    def __init__(
        self,
        message: str = "native decompiler result failed validation",
    ) -> None:
        super().__init__("result.invalid", message, 5)


def _mapping(
    value: Any,
    label: str,
    *,
    keys: set[str] | None = None,
) -> dict[str, Any]:
    if not isinstance(value, dict) or (keys is not None and set(value) != keys):
        raise ResultValidationError(f"{label} has an unsupported object shape")
    return value


def _array(
    value: Any,
    label: str,
    *,
    maximum: int | None = None,
) -> list[Any]:
    if not isinstance(value, list) or (
        maximum is not None and len(value) > maximum
    ):
        raise ResultValidationError(f"{label} must be a bounded array")
    return value


def _text(
    value: Any,
    label: str,
    *,
    allow_empty: bool = True,
    maximum: int = 4 * 1024 * 1024,
) -> str:
    if (
        not isinstance(value, str)
        or (not allow_empty and not value)
        or len(value.encode("utf-8")) > maximum
        or "\x00" in value
        or any(0xD800 <= ord(character) <= 0xDFFF for character in value)
    ):
        raise ResultValidationError(f"{label} must be valid bounded text")
    return value


def _boolean(value: Any, label: str) -> bool:
    if type(value) is not bool:
        raise ResultValidationError(f"{label} must be a boolean")
    return value


def _integer(
    value: Any,
    label: str,
    *,
    minimum: int = 0,
    maximum: int = (1 << 64) - 1,
) -> int:
    if type(value) is not int or not minimum <= value <= maximum:
        raise ResultValidationError(f"{label} must be a bounded integer")
    return value


def _address(value: Any, label: str) -> int:
    try:
        return parse_address(value, label)
    except ValueError as error:
        raise ResultValidationError(str(error)) from error


def _sha(value: Any, label: str) -> str:
    text = _text(value, label, allow_empty=False, maximum=64)
    if len(text) != 64 or any(
        character not in "0123456789abcdef" for character in text
    ):
        raise ResultValidationError(f"{label} must be a lowercase SHA-256")
    return text


def _hex_bytes(value: Any, label: str, *, byte_count: int) -> str:
    text = _text(value, label, allow_empty=False, maximum=byte_count * 2)
    if len(text) != byte_count * 2 or any(
        character not in "0123456789abcdef" for character in text
    ):
        raise ResultValidationError(
            f"{label} must encode exactly {byte_count} bytes"
        )
    return text


def _string_array(
    value: Any,
    label: str,
    *,
    maximum: int = 1_000_000,
) -> list[str]:
    result: list[str] = []
    for index, item in enumerate(_array(value, label, maximum=maximum)):
        result.append(
            _text(
                item,
                f"{label}[{index}]",
                allow_empty=False,
                maximum=16 * 1024,
            )
        )
    if result != sorted(set(result)):
        raise ResultValidationError(f"{label} must be unique and canonical")
    return result


def _source_range(value: Any, label: str) -> None:
    item = _mapping(
        value,
        label,
        keys={"imageId", "startAddress", "endAddressExclusive"},
    )
    _text(item["imageId"], f"{label}.imageId", allow_empty=False, maximum=16 * 1024)
    start = _address(item["startAddress"], f"{label}.startAddress")
    end = _address(item["endAddressExclusive"], f"{label}.endAddressExclusive")
    if end <= start:
        raise ResultValidationError(f"{label} must be non-empty")


def _validate_schema_when_available(value: dict[str, Any]) -> None:
    try:
        import jsonschema  # type: ignore
    except ImportError:
        return
    path = Path(__file__).resolve().parents[1] / "schemas" / "result.schema.json"
    try:
        schema = json.loads(path.read_text(encoding="utf-8"))
        jsonschema.Draft202012Validator(schema).validate(value)
    except Exception as error:
        raise ResultValidationError(
            "result does not conform to the closed JSON schema"
        ) from error


def _reconstruct_output(result: dict[str, Any]) -> NativeProviderOutput:
    engine = _mapping(
        result.get("engine"),
        "engine",
        keys={
            "backendId",
            "componentId",
            "version",
            "gitRevision",
            "serviceName",
            "serviceVersion",
            "hostMode",
            "programRevision",
            "languageId",
            "openProgram",
            "wheelFilename",
            "wheelSha256",
            "wheelPlatform",
            "extensionSha256",
            "materializationSha256",
            "reportedCapabilities",
        },
    )
    if (
        engine["backendId"] != ENGINE_BACKEND_ID
        or engine["componentId"] != ENGINE_COMPONENT_ID
        or engine["version"] != ENGINE_VERSION
        or engine["gitRevision"] != ENGINE_GIT_REVISION
        or engine["serviceName"] != ENGINE_SERVICE_NAME
        or engine["serviceVersion"] != ENGINE_SERVICE_VERSION
        or engine["hostMode"] != ENGINE_HOST_MODE
        or engine["languageId"] != ENGINE_LANGUAGE_ID
    ):
        raise ResultValidationError("result engine identity is incorrect")

    reported_values = _array(
        engine["reportedCapabilities"],
        "engine.reportedCapabilities",
        maximum=MAX_CAPABILITY_COUNT,
    )
    capabilities: list[NativeCapability] = []
    for index, raw in enumerate(reported_values):
        item = _mapping(
            raw,
            f"reportedCapabilities[{index}]",
            keys={"id", "status"},
        )
        capabilities.append(
            NativeCapability(
                capability_id=_text(
                    item["id"],
                    "capability id",
                    allow_empty=False,
                    maximum=1024,
                ),
                status=_text(
                    item["status"],
                    "capability status",
                    allow_empty=False,
                    maximum=1024,
                ),
            )
        )
    if capabilities != sorted(
        capabilities,
        key=lambda item: (item.capability_id, item.status),
    ):
        raise ResultValidationError("reported capabilities are not in canonical order")
    if len({item.capability_id for item in capabilities}) != len(capabilities):
        raise ResultValidationError(
            "reported capabilities contain duplicate identifiers"
        )
    observed = {item.capability_id: item.status for item in capabilities}
    for capability_id, status in REQUIRED_NATIVE_CAPABILITIES.items():
        if observed.get(capability_id) != status:
            raise ResultValidationError("result lacks a required native capability")

    wheel = _text(
        engine["wheelFilename"],
        "engine.wheelFilename",
        allow_empty=False,
        maximum=4096,
    )
    approved = APPROVED_WHEELS.get(wheel)
    if approved is None:
        raise ResultValidationError("result uses an unapproved wheel")
    wheel_sha = _sha(engine["wheelSha256"], "engine.wheelSha256")
    wheel_platform = _text(
        engine["wheelPlatform"],
        "engine.wheelPlatform",
        allow_empty=False,
        maximum=4096,
    )
    if wheel_sha != approved.sha256 or wheel_platform != approved.platform:
        raise ResultValidationError("result wheel identity is inconsistent")

    opened = _mapping(
        engine["openProgram"],
        "engine.openProgram",
        keys={
            "programName",
            "languageId",
            "compilerSpec",
            "reportedImageBase",
            "imageBaseDisposition",
        },
    )
    opened_language = _text(
        opened["languageId"],
        "engine.openProgram.languageId",
        allow_empty=False,
        maximum=4096,
    )
    opened_compiler = _text(
        opened["compilerSpec"],
        "engine.openProgram.compilerSpec",
        allow_empty=False,
        maximum=4096,
    )
    if (
        opened_language != ENGINE_LANGUAGE_ID
        or opened_compiler != ENGINE_COMPILER_SPEC_ID
    ):
        raise ResultValidationError("open-program architecture identity is incorrect")
    reported_image_base = _address(
        opened["reportedImageBase"],
        "engine.openProgram.reportedImageBase",
    )
    disposition = _text(
        opened["imageBaseDisposition"],
        "engine.openProgram.imageBaseDisposition",
        allow_empty=False,
        maximum=64,
    )
    if disposition not in {"unreported", "matches-request"}:
        raise ResultValidationError(
            "open-program image-base disposition is unsupported"
        )

    records = _mapping(
        result.get("backendRecords"),
        "backendRecords",
        keys={"decompilation", "function", "instructions"},
    )
    decomp = _mapping(
        records["decompilation"],
        "backendRecords.decompilation",
        keys={"functionEntryAddress", "pseudocode", "completed", "fallback"},
    )
    function = _mapping(
        records["function"],
        "backendRecords.function",
        keys={
            "entryAddress",
            "name",
            "startAddress",
            "reportedEndAddress",
            "normalizedEndAddressExclusive",
            "size",
            "namespace",
            "prototype",
            "isThunk",
            "parameterCount",
            "rawSourceSha256",
            "effectiveSourceSha256",
            "appliedPatchIds",
            "imageQualifiedSourceRange",
        },
    )
    _sha(function["rawSourceSha256"], "backendRecords.function.rawSourceSha256")
    _sha(
        function["effectiveSourceSha256"],
        "backendRecords.function.effectiveSourceSha256",
    )
    _string_array(
        function["appliedPatchIds"],
        "backendRecords.function.appliedPatchIds",
    )
    _address(
        function["normalizedEndAddressExclusive"],
        "function.normalizedEndAddressExclusive",
    )
    _source_range(
        function["imageQualifiedSourceRange"],
        "function.imageQualifiedSourceRange",
    )

    instruction_values = _array(
        records["instructions"],
        "backendRecords.instructions",
        maximum=MAX_INSTRUCTION_COUNT,
    )
    instructions: list[NativeInstruction] = []
    for index, raw in enumerate(instruction_values):
        item = _mapping(
            raw,
            f"instructions[{index}]",
            keys={
                "id",
                "index",
                "address",
                "endAddressExclusive",
                "length",
                "mnemonic",
                "operandText",
                "disassembly",
                "rawBytesHex",
                "effectiveBytesHex",
                "rawSourceSha256",
                "effectiveSourceSha256",
                "appliedPatchIds",
                "imageQualifiedSourceRange",
            },
        )
        if item["id"] != f"nativeinsn{index:06d}" or item["index"] != index:
            raise ResultValidationError("instruction identifiers are not canonical")
        length = _integer(
            item["length"],
            "instruction.length",
            minimum=1,
            maximum=16,
        )
        _hex_bytes(
            item["rawBytesHex"],
            "instruction.rawBytesHex",
            byte_count=length,
        )
        _hex_bytes(
            item["effectiveBytesHex"],
            "instruction.effectiveBytesHex",
            byte_count=length,
        )
        _sha(item["rawSourceSha256"], "instruction.rawSourceSha256")
        _sha(item["effectiveSourceSha256"], "instruction.effectiveSourceSha256")
        _string_array(
            item["appliedPatchIds"],
            "instruction.appliedPatchIds",
        )
        _address(item["endAddressExclusive"], "instruction.endAddressExclusive")
        _source_range(
            item["imageQualifiedSourceRange"],
            "instruction.imageQualifiedSourceRange",
        )
        instructions.append(
            NativeInstruction(
                address=_address(item["address"], "instruction.address"),
                mnemonic=_text(
                    item["mnemonic"],
                    "instruction.mnemonic",
                    allow_empty=False,
                    maximum=16 * 1024,
                ),
                operand_text=_text(
                    item["operandText"],
                    "instruction.operandText",
                    maximum=16 * 1024,
                ),
                disassembly=_text(
                    item["disassembly"],
                    "instruction.disassembly",
                    allow_empty=False,
                    maximum=16 * 1024,
                ),
                length=length,
            )
        )

    return NativeProviderOutput(
        engine=NativeEngineStatus(
            service_name=engine["serviceName"],
            service_version=engine["serviceVersion"],
            host_mode=engine["hostMode"],
            program_revision=_integer(
                engine["programRevision"],
                "engine.programRevision",
            ),
            capabilities=tuple(capabilities),
            wheel_filename=wheel,
            wheel_sha256=wheel_sha,
            wheel_platform=wheel_platform,
            extension_sha256=_sha(
                engine["extensionSha256"],
                "engine.extensionSha256",
            ),
            materialization_sha256=_sha(
                engine["materializationSha256"],
                "engine.materializationSha256",
            ),
        ),
        opened_program=NativeOpenProgram(
            program_name=_text(
                opened["programName"],
                "engine.openProgram.programName",
                allow_empty=False,
                maximum=16 * 1024,
            ),
            language_id=opened_language,
            compiler_spec=opened_compiler,
            reported_image_base=reported_image_base,
        ),
        decompilation=NativeDecompilation(
            function_entry=_address(
                decomp["functionEntryAddress"],
                "decompilation.functionEntryAddress",
            ),
            pseudocode=_text(
                decomp["pseudocode"],
                "decompilation.pseudocode",
                allow_empty=False,
            ),
            completed=_boolean(
                decomp["completed"],
                "decompilation.completed",
            ),
            fallback=_boolean(
                decomp["fallback"],
                "decompilation.fallback",
            ),
        ),
        function=NativeFunction(
            entry_address=_address(
                function["entryAddress"],
                "function.entryAddress",
            ),
            name=_text(
                function["name"],
                "function.name",
                maximum=16 * 1024,
            ),
            start_address=_address(
                function["startAddress"],
                "function.startAddress",
            ),
            end_address=_address(
                function["reportedEndAddress"],
                "function.reportedEndAddress",
            ),
            size=_integer(function["size"], "function.size"),
            namespace_name=_text(
                function["namespace"],
                "function.namespace",
                maximum=16 * 1024,
            ),
            prototype=_text(function["prototype"], "function.prototype"),
            is_thunk=_boolean(function["isThunk"], "function.isThunk"),
            parameter_count=_integer(
                function["parameterCount"],
                "function.parameterCount",
                maximum=100_000,
            ),
        ),
        instructions=tuple(instructions),
    )


def validate_result(result: Any, *, request: AnalysisRequest) -> None:
    value = _mapping(
        result,
        "result",
        keys={
            "schemaVersion",
            "status",
            "analysisLevel",
            "contractCompleteness",
            "requestId",
            "requestSha256",
            "engine",
            "authority",
            "function",
            "capabilities",
            "analysisSemantics",
            "presentation",
            "backendRecords",
            "recoveredVariables",
            "typeCandidates",
            "warnings",
            "resourceUsage",
            "contentHash",
        },
    )
    if value["schemaVersion"] != RESULT_SCHEMA_VERSION or value["status"] != "ok":
        raise ResultValidationError("result protocol identity is unsupported")
    if (
        value["analysisLevel"] != ANALYSIS_LEVEL
        or value["contractCompleteness"] != CONTRACT_COMPLETENESS
    ):
        raise ResultValidationError("result analysis contract identity is incorrect")
    if (
        value["requestId"] != request.request_id
        or value["requestSha256"] != request.request_sha256
    ):
        raise ResultValidationError("result does not bind to the exact request")
    if _array(value["recoveredVariables"], "recoveredVariables"):
        raise ResultValidationError("DCP-03B3 must not claim recovered variables")
    if _array(value["typeCandidates"], "typeCandidates"):
        raise ResultValidationError("DCP-03B3 must not claim type candidates")

    content_hash = _sha(value["contentHash"], "result.contentHash")
    unhashed = dict(value)
    del unhashed["contentHash"]
    if canonical_sha256(unhashed) != content_hash:
        raise ResultValidationError(
            "result contentHash does not match the canonical result"
        )

    expected_carrier = build_macho_carrier(request)
    authority = _mapping(
        value["authority"],
        "authority",
        keys={
            "model",
            "imageId",
            "imageUUID",
            "preferredLoadAddress",
            "effectiveLoadImageSha256",
            "loadImage",
            "carrier",
        },
    )
    if authority != {
        "model": "caller-owned-raw-memory-with-derived-effective-carrier",
        "imageId": request.image_id,
        "imageUUID": request.image_uuid,
        "preferredLoadAddress": f"0x{request.preferred_load_address:x}",
        "effectiveLoadImageSha256": canonical_sha256(expected_carrier.load_image.output),
        "loadImage": expected_carrier.load_image.output,
        "carrier": expected_carrier.manifest,
    }:
        raise ResultValidationError(
            "result authority differs from deterministic request-derived effective memory"
        )

    _validate_schema_when_available(value)
    output = _reconstruct_output(value)
    try:
        expected = build_result(
            request=request,
            carrier=expected_carrier,
            output=output,
        )
    except PilotError as error:
        raise ResultValidationError(
            "result contains invalid native structured records"
        ) from error
    if value != expected:
        raise ResultValidationError(
            "result differs from independent structured-record normalization"
        )
