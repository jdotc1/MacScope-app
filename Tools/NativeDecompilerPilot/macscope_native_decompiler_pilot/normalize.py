"""Normalize direct libghidra v0.0.2 records into the DCP-03B3 result.

Rendered pseudocode is presentation-only. Every semantic record emitted by this
tranche comes directly from the native function or instruction API. Instruction
semantics bind to DCP-03B2's independently derived effective bytes, while raw
caller bytes and every intersecting patch remain explicit provenance.
"""

from __future__ import annotations

from macscope_decompiler_proof.canonical import (
    bytes_sha256,
    canonical_sha256,
    format_address,
)
from macscope_decompiler_proof.request import AnalysisRequest

from .carrier import CarrierArtifact
from .contract import (
    ANALYSIS_LEVEL,
    ANALYSIS_SEMANTICS,
    CAPABILITY_TRUTH,
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
    RESULT_SCHEMA_VERSION,
)
from .errors import NormalizationError
from .provider import NativeInstruction, NativeProviderOutput


def _source_range(
    request: AnalysisRequest,
    start: int,
    end_exclusive: int,
) -> dict[str, str]:
    return {
        "imageId": request.image_id,
        "startAddress": format_address(start),
        "endAddressExclusive": format_address(end_exclusive),
    }


def _validated_instructions(
    request: AnalysisRequest,
    carrier: CarrierArtifact,
    output: NativeProviderOutput,
) -> tuple[NativeInstruction, ...]:
    instructions = tuple(sorted(output.instructions, key=lambda item: item.address))
    if not instructions:
        raise NormalizationError("native instruction records are unavailable")
    if len({item.address for item in instructions}) != len(instructions):
        raise NormalizationError("native instruction records contain duplicate addresses")
    if len(instructions) > request.budgets.max_instructions:
        raise NormalizationError("native instruction count exceeds the caller budget")

    cursor = request.function_entry
    for instruction in instructions:
        if instruction.address != cursor:
            raise NormalizationError(
                "native instructions do not contiguously cover the function"
            )
        if instruction.address & 0x3 or instruction.length != 4:
            raise NormalizationError(
                "native instruction record violates the bounded AArch64 model"
            )
        end_exclusive = instruction.address + instruction.length
        if end_exclusive > request.function_end:
            raise NormalizationError(
                "native instruction exceeds the caller-owned function extent"
            )
        request.read(
            instruction.address,
            end_exclusive,
            require_executable=True,
        )
        carrier.load_image.read(
            instruction.address,
            end_exclusive,
            require_executable=True,
        )
        if not instruction.mnemonic or not instruction.disassembly:
            raise NormalizationError("native instruction record is incomplete")
        cursor = end_exclusive
    if cursor != request.function_end:
        raise NormalizationError(
            "native instructions do not cover the complete caller-owned function extent"
        )
    return instructions


def _validate_native_output(
    request: AnalysisRequest,
    carrier: CarrierArtifact,
    output: NativeProviderOutput,
) -> tuple[NativeInstruction, ...]:
    if carrier.load_image.request.request_sha256 != request.request_sha256:
        raise NormalizationError("carrier effective image belongs to another request")
    if carrier.manifest.get("requestSha256") != request.request_sha256:
        raise NormalizationError("carrier manifest belongs to another request")
    if carrier.manifest.get("carrierSha256") != bytes_sha256(carrier.data):
        raise NormalizationError("carrier bytes do not match the carrier manifest")

    if (
        output.engine.service_name != ENGINE_SERVICE_NAME
        or output.engine.service_version != ENGINE_SERVICE_VERSION
        or output.engine.host_mode != ENGINE_HOST_MODE
    ):
        raise NormalizationError(
            "native service identity does not match the pinned engine"
        )
    if output.engine.program_revision < 0:
        raise NormalizationError("native program revision is invalid")
    opened = output.opened_program
    if (
        opened.language_id != ENGINE_LANGUAGE_ID
        or opened.compiler_spec != ENGINE_COMPILER_SPEC_ID
        or not opened.program_name
        or opened.reported_image_base not in {0, request.preferred_load_address}
    ):
        raise NormalizationError(
            "native open-program record is inconsistent with the request"
        )

    decompilation = output.decompilation
    if (
        decompilation.function_entry != request.function_entry
        or not decompilation.completed
        or decompilation.fallback
        or not decompilation.pseudocode
    ):
        raise NormalizationError("native decompilation is incomplete or fallback-only")

    function = output.function
    if (
        function.entry_address != request.function_entry
        or function.start_address != request.function_entry
    ):
        raise NormalizationError(
            "native function record identifies a different function"
        )
    if function.size != request.function_size:
        raise NormalizationError(
            "native function size differs from the caller-owned function extent"
        )
    # Some upstream APIs represent end_address inclusively while others expose
    # the half-open end. Preserve the reported value, but bind semantics to the
    # exact caller-owned extent only when size and one of those forms agree.
    if function.end_address not in {request.function_end - 1, request.function_end}:
        raise NormalizationError(
            "native function end differs from the caller-owned function extent"
        )
    request.read(
        request.function_entry,
        request.function_end,
        require_executable=True,
    )
    carrier.load_image.read(
        request.function_entry,
        request.function_end,
        require_executable=True,
    )
    return _validated_instructions(request, carrier, output)


def _instruction_record(
    request: AnalysisRequest,
    carrier: CarrierArtifact,
    instruction: NativeInstruction,
    index: int,
) -> dict[str, object]:
    end_exclusive = instruction.address + instruction.length
    raw_source = request.read(
        instruction.address,
        end_exclusive,
        require_executable=True,
    )
    effective_source = carrier.load_image.read(
        instruction.address,
        end_exclusive,
        require_executable=True,
    )
    return {
        "id": f"nativeinsn{index:06d}",
        "index": index,
        "address": format_address(instruction.address),
        "endAddressExclusive": format_address(end_exclusive),
        "length": instruction.length,
        "mnemonic": instruction.mnemonic,
        "operandText": instruction.operand_text,
        "disassembly": instruction.disassembly,
        "rawBytesHex": raw_source.hex(),
        "effectiveBytesHex": effective_source.hex(),
        "rawSourceSha256": bytes_sha256(raw_source),
        "effectiveSourceSha256": bytes_sha256(effective_source),
        "appliedPatchIds": carrier.load_image.patch_ids_intersecting(
            instruction.address,
            end_exclusive,
        ),
        "imageQualifiedSourceRange": _source_range(
            request,
            instruction.address,
            end_exclusive,
        ),
    }


def _function_provenance(
    request: AnalysisRequest,
    carrier: CarrierArtifact,
) -> dict[str, object]:
    raw_source = request.read(
        request.function_entry,
        request.function_end,
        require_executable=True,
    )
    effective_source = carrier.load_image.read(
        request.function_entry,
        request.function_end,
        require_executable=True,
    )
    return {
        "rawSourceSha256": bytes_sha256(raw_source),
        "effectiveSourceSha256": bytes_sha256(effective_source),
        "appliedPatchIds": carrier.load_image.patch_ids_intersecting(
            request.function_entry,
            request.function_end,
        ),
    }


def _backend_records(
    request: AnalysisRequest,
    carrier: CarrierArtifact,
    output: NativeProviderOutput,
    instructions: tuple[NativeInstruction, ...],
) -> dict[str, object]:
    function = output.function
    provenance = _function_provenance(request, carrier)
    return {
        "decompilation": {
            "functionEntryAddress": format_address(
                output.decompilation.function_entry
            ),
            "pseudocode": output.decompilation.pseudocode,
            "completed": output.decompilation.completed,
            "fallback": output.decompilation.fallback,
        },
        "function": {
            "entryAddress": format_address(function.entry_address),
            "name": function.name,
            "startAddress": format_address(function.start_address),
            "reportedEndAddress": format_address(function.end_address),
            "normalizedEndAddressExclusive": format_address(request.function_end),
            "size": function.size,
            "namespace": function.namespace_name,
            "prototype": function.prototype,
            "isThunk": function.is_thunk,
            "parameterCount": function.parameter_count,
            **provenance,
            "imageQualifiedSourceRange": _source_range(
                request,
                request.function_entry,
                request.function_end,
            ),
        },
        "instructions": [
            _instruction_record(request, carrier, instruction, index)
            for index, instruction in enumerate(instructions)
        ],
    }


def _warnings(
    request: AnalysisRequest,
    carrier: CarrierArtifact,
    output: NativeProviderOutput,
) -> list[str]:
    values = {
        "native-heritage-export-unavailable-libghidra-v0.0.2",
        "tokenized-pseudocode-unavailable-libghidra-v0.0.2",
        "recovered-variables-unavailable-libghidra-v0.0.2",
        "structured-type-candidates-unavailable-libghidra-v0.0.2",
        "native-basic-block-enumeration-not-accepted-dcp03b3",
        "native-cfg-edge-enumeration-not-accepted-dcp03b3",
        "native-timeout-parameter-not-enforced-by-libghidra-v0.0.2",
    }
    if request.type_hints:
        values.add("request-type-hints-not-applied")
    patches = carrier.load_image.output.get("patches")
    unmapped = carrier.load_image.output.get("unmappedEvidence")
    if not isinstance(patches, list) or not isinstance(unmapped, list):
        raise NormalizationError("effective load-image evidence is malformed")
    if patches:
        values.add("effective-load-image-patches-applied")
    if unmapped:
        values.add("unmapped-address-metadata-preserved")
    if any(isinstance(item, dict) and item.get("authenticated") is True for item in patches):
        values.add("authenticated-pointer-normalized-without-runtime-pac-validation")
    if output.function.name and output.function.name != request.function_name:
        values.add("native-function-name-differs-from-request")
    if output.opened_program.reported_image_base == 0:
        values.add("native-open-response-image-base-unreported")
    return sorted(values)


def build_result(
    *,
    request: AnalysisRequest,
    carrier: CarrierArtifact,
    output: NativeProviderOutput,
) -> dict[str, object]:
    instructions = _validate_native_output(request, carrier, output)
    records = _backend_records(request, carrier, output, instructions)
    provenance = _function_provenance(request, carrier)
    patches = carrier.load_image.output["patches"]
    unmapped = carrier.load_image.output["unmappedEvidence"]
    assert isinstance(patches, list)
    assert isinstance(unmapped, list)

    result: dict[str, object] = {
        "schemaVersion": RESULT_SCHEMA_VERSION,
        "status": "ok",
        "analysisLevel": ANALYSIS_LEVEL,
        "contractCompleteness": CONTRACT_COMPLETENESS,
        "requestId": request.request_id,
        "requestSha256": request.request_sha256,
        "engine": {
            "backendId": ENGINE_BACKEND_ID,
            "componentId": ENGINE_COMPONENT_ID,
            "version": ENGINE_VERSION,
            "gitRevision": ENGINE_GIT_REVISION,
            "serviceName": output.engine.service_name,
            "serviceVersion": output.engine.service_version,
            "hostMode": output.engine.host_mode,
            "programRevision": output.engine.program_revision,
            "languageId": ENGINE_LANGUAGE_ID,
            "openProgram": {
                "programName": output.opened_program.program_name,
                "languageId": output.opened_program.language_id,
                "compilerSpec": output.opened_program.compiler_spec,
                "reportedImageBase": format_address(
                    output.opened_program.reported_image_base
                ),
                "imageBaseDisposition": (
                    "unreported"
                    if output.opened_program.reported_image_base == 0
                    else "matches-request"
                ),
            },
            "wheelFilename": output.engine.wheel_filename,
            "wheelSha256": output.engine.wheel_sha256,
            "wheelPlatform": output.engine.wheel_platform,
            "extensionSha256": output.engine.extension_sha256,
            "materializationSha256": output.engine.materialization_sha256,
            "reportedCapabilities": [
                {
                    "id": item.capability_id,
                    "status": item.status,
                }
                for item in sorted(
                    output.engine.capabilities,
                    key=lambda item: (item.capability_id, item.status),
                )
            ],
        },
        "authority": {
            "model": "caller-owned-raw-memory-with-derived-effective-carrier",
            "imageId": request.image_id,
            "imageUUID": request.image_uuid,
            "preferredLoadAddress": format_address(
                request.preferred_load_address
            ),
            "effectiveLoadImageSha256": canonical_sha256(
                carrier.load_image.output
            ),
            "loadImage": carrier.load_image.output,
            "carrier": carrier.manifest,
        },
        "function": {
            "functionId": request.function_id,
            "requestedName": request.function_name,
            "entryAddress": format_address(request.function_entry),
            "endAddressExclusive": format_address(request.function_end),
            **provenance,
            "imageQualifiedSourceRange": _source_range(
                request,
                request.function_entry,
                request.function_end,
            ),
            "nativeName": output.function.name,
            "nativePrototype": output.function.prototype,
        },
        "capabilities": dict(CAPABILITY_TRUTH),
        "analysisSemantics": dict(ANALYSIS_SEMANTICS),
        "presentation": {
            "pseudocode": output.decompilation.pseudocode,
            "completed": output.decompilation.completed,
            "fallback": output.decompilation.fallback,
            "semanticInput": False,
        },
        "backendRecords": records,
        "recoveredVariables": [],
        "typeCandidates": [],
        "warnings": _warnings(request, carrier, output),
        "resourceUsage": {
            "carrierBytes": len(carrier.data),
            "rawFunctionBytes": request.function_size,
            "effectiveFunctionBytes": request.function_size,
            "appliedPatchCount": len(patches),
            "unmappedEvidenceCount": len(unmapped),
            "pseudocodeBytes": len(
                output.decompilation.pseudocode.encode("utf-8")
            ),
            "nativeInstructionCount": len(instructions),
            "nativeInstructionBytes": sum(
                item.length for item in instructions
            ),
            "nativeFunctionRecordCount": 1,
            "tokenCount": 0,
            "localRecordCount": 0,
            "nativeBasicBlockCount": 0,
            "nativeCFGEdgeCount": 0,
            "recoveredVariableCount": 0,
            "typeCandidateCount": 0,
        },
    }
    result["contentHash"] = canonical_sha256(result)
    return result
