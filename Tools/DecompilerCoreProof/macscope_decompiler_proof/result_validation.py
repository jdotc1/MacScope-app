"""Semantic validation for the DCP-03 structured result boundary.

JSON Schema closes the serialized shape.  This verifier enforces relationships
that schema cannot express: effective-memory patch semantics and provenance,
graph consistency, image-qualified source ranges, SSA definition/use integrity,
phi predecessor identity, MemorySSA chains, resource counts, and the canonical
content hash.
"""

from __future__ import annotations

import copy
import re
from collections.abc import Iterator, Mapping, Sequence
from typing import Any, TYPE_CHECKING, TypeVar

from .canonical import UINT64_MAX, bytes_sha256, canonical_sha256, format_address, parse_address
from .contract import (
    ANALYSIS_LEVEL,
    ANALYSIS_SEMANTICS,
    CAPABILITY_TRUTH,
    CONTRACT_COMPLETENESS,
    ENGINE_BACKEND_ID,
    ENGINE_COMPONENT_ID,
    ENGINE_GIT_REVISION,
    ENGINE_LANGUAGE_ALLOWLIST,
    ENGINE_MINIMUM_RESOURCE_COUNT,
    ENGINE_VERSION,
    RESULT_SCHEMA_VERSION,
    expected_warnings,
)
from .dataflow import DataflowDerivationError, derive_dataflow
from .load_image import (
    LOAD_IMAGE_MODEL,
    SUPPORTED_FIXUP_KINDS,
    SUPPORTED_RELOCATION_KINDS,
    EffectiveLoadImageError,
    build_effective_load_image,
    encode_relocation_replacement,
)
from .register_dataflow import (
    DARWIN_CALL_GPR_CLOBBERS,
    DARWIN_CALL_GPR_INPUTS,
    DARWIN_CALL_SIMD_INPUTS,
    REGISTER_MODEL,
    RegisterDataflowDerivationError,
    derive_register_analysis,
)

if TYPE_CHECKING:
    from .request import AnalysisRequest

_LeftValue = TypeVar("_LeftValue")
_RightValue = TypeVar("_RightValue")

_RESULT_FIELDS = {
    "schemaVersion",
    "status",
    "analysisLevel",
    "contractCompleteness",
    "requestId",
    "requestSha256",
    "engine",
    "capabilities",
    "analysisSemantics",
    "image",
    "loadImage",
    "function",
    "instructions",
    "values",
    "pcodeOps",
    "basicBlocks",
    "edges",
    "calls",
    "evidenceInputs",
    "ssaValues",
    "ssaBindings",
    "phis",
    "heritage",
    "memoryVersions",
    "memoryPhis",
    "memoryEffects",
    "registerAnalysis",
    "recoveredVariables",
    "recoveredTypes",
    "structuredRegions",
    "pseudocodeTokens",
    "warnings",
    "resourceUsage",
    "contentHash",
}
_ID_PATTERNS = {
    "value": re.compile(r"^v[0-9]{6}$"),
    "operation": re.compile(r"^op[0-9]{6}$"),
    "block": re.compile(r"^bb_[0-9a-f]+$"),
    "edge": re.compile(r"^edge[0-9]{6}$"),
    "call": re.compile(r"^call[0-9]{6}$"),
    "ssa": re.compile(r"^ssa[0-9]{6}$"),
    "binding": re.compile(r"^bind[0-9]{6}$"),
    "phi": re.compile(r"^phi[0-9]{6}$"),
    "use": re.compile(r"^use[0-9]{6}$"),
    "memory": re.compile(r"^mem[0-9]{6}$"),
    "memoryPhi": re.compile(r"^mphi[0-9]{6}$"),
    "memoryEffect": re.compile(r"^me[0-9]{6}$"),
    "registerView": re.compile(r"^rview[0-9]{6}$"),
    "registerVersion": re.compile(r"^reg[0-9]{6}$"),
    "registerBinding": re.compile(r"^rbind[0-9]{6}$"),
    "registerPhi": re.compile(r"^rphi[0-9]{6}$"),
    "callRegisterEffect": re.compile(r"^ce[0-9]{6}$"),
    "loadImagePatch": re.compile(r"^patch[0-9]{6}$"),
}
_SHA256 = re.compile(r"^[0-9a-f]{64}$")
_UUID = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
_IDENTIFIER = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:-]{0,255}$")
_OPCODE = re.compile(r"^[A-Z][A-Z0-9_]*$")
_ENGINE_RESOURCE_NAME = re.compile(r"^(?!/)(?!.*(?:^|/)\.\.(?:/|$)).+$")
_PERMISSIONS = re.compile(r"^[r-][w-][x-]$")

_MEMORY_KIND_BY_OPCODE = {
    "LOAD": "read",
    "STORE": "write",
    "CALL": "callClobber",
    "CALLIND": "callClobber",
    "CALLOTHER": "unknownClobber",
}

_OBJECT_FIELDS = {
    "engine": frozenset(
        {
            "backend",
            "componentId",
            "version",
            "gitRevision",
            "languageId",
            "compilerSpecId",
            "resources",
        }
    ),
    "engineResource": frozenset({"name", "byteCount", "sha256"}),
    "image": frozenset({"imageId", "uuid", "preferredLoadAddress", "memoryRegions"}),
    "memoryRegion": frozenset({"name", "startAddress", "endAddressExclusive", "permissions", "byteCount", "sha256"}),
    "loadImage": frozenset({"model", "memoryRegions", "patches", "unmappedEvidence"}),
    "loadImageModel": frozenset(
        {
            "architecture",
            "byteOrder",
            "pointerWidthBits",
            "relocationModel",
            "fixupModel",
            "patchPolicy",
            "authenticatedPointerTreatment",
            "supportedRelocationKinds",
            "supportedFixupKinds",
        }
    ),
    "effectiveMemoryRegion": frozenset(
        {
            "name",
            "startAddress",
            "endAddressExclusive",
            "permissions",
            "byteCount",
            "rawSha256",
            "effectiveSha256",
            "appliedPatchIds",
        }
    ),
    "loadImagePatch": frozenset(
        {
            "id",
            "sourceKind",
            "sourceIndex",
            "address",
            "width",
            "kind",
            "encoding",
            "targetAddress",
            "symbol",
            "addend",
            "authenticated",
            "key",
            "diversity",
            "originalBytesHex",
            "effectiveBytesHex",
            "sourceRange",
        }
    ),
    "unmappedAddressMetadata": frozenset(
        {"sourceKind", "sourceIndex", "address", "kind", "reason"}
    ),
    "function": frozenset(
        {
            "functionId",
            "name",
            "entryAddress",
            "endAddressExclusive",
            "byteCount",
            "sourceSha256",
            "effectiveSha256",
            "appliedPatchIds",
        }
    ),
    "instruction": frozenset(
        {"index", "address", "size", "bytesHex", "mnemonic", "body", "pcodeOpIds", "sourceRange"}
    ),
    "value": frozenset({"id", "space", "offset", "size", "storageClass", "registerName", "scopeInstructionAddress"}),
    "pcodeOp": frozenset(
        {
            "id",
            "instructionIndex",
            "sequence",
            "opcode",
            "output",
            "inputs",
            "directTargetAddress",
            "sourceRange",
        }
    ),
    "terminator": frozenset({"kind", "pcodeOpId", "directTargetAddress"}),
    "basicBlock": frozenset(
        {
            "id",
            "startAddress",
            "endAddressExclusive",
            "instructionIndices",
            "predecessorEdgeIds",
            "successorEdgeIds",
            "terminator",
        }
    ),
    "edge": frozenset({"id", "sourceBlockId", "targetBlockId", "targetAddress", "kind", "pcodeOpId"}),
    "symbol": frozenset({"imageId", "address", "name", "kind"}),
    "call": frozenset({"id", "pcodeOpId", "kind", "targetAddress", "targetSymbol", "sourceRange"}),
    "relocation": frozenset({"address", "kind", "targetAddress", "symbol", "addend"}),
    "fixup": frozenset({"address", "kind", "targetAddress", "authenticated", "key", "diversity"}),
    "typeHint": frozenset({"subjectKind", "address", "typeName", "confidence", "source"}),
    "evidenceInputs": frozenset({"symbols", "relocations", "fixups", "typeHints"}),
    "ssaValue": frozenset({"id", "kind", "storageValueId", "definingPcodeOpId", "definingPhiId", "sourceRange"}),
    "ssaBinding": frozenset({"id", "pcodeOpId", "inputSsaValueIds", "outputSsaValueId"}),
    "phi": frozenset({"id", "blockId", "storageValueId", "outputSsaValueId", "incoming", "isTrivial"}),
    "phiIncoming": frozenset({"sourceKind", "sourceBlockId", "edgeId", "ssaValueId"}),
    "heritageUse": frozenset({"id", "pcodeOpId", "operandIndex", "storageValueId", "ssaValueId", "sourceRange"}),
    "memoryVersion": frozenset({"id", "partition", "kind", "definingPcodeOpId", "definingMemoryPhiId", "sourceRange"}),
    "memoryPhi": frozenset({"id", "blockId", "partition", "outputMemoryVersionId", "incoming", "isTrivial"}),
    "memoryPhiIncoming": frozenset({"sourceKind", "sourceBlockId", "edgeId", "memoryVersionId"}),
    "memoryEffect": frozenset(
        {
            "id",
            "pcodeOpId",
            "kind",
            "partition",
            "inputMemoryVersionId",
            "outputMemoryVersionId",
            "sourceRange",
        }
    ),
    "registerAnalysis": frozenset({"model", "views", "versions", "bindings", "phis", "callEffects"}),
    "registerModel": frozenset(
        {
            "architecture",
            "platform",
            "callingConvention",
            "abiSpecification",
            "gprCanonicalWidthBits",
            "gprAliasCoverage",
            "simdSsaCoverage",
            "conditionFlagSsaCoverage",
            "callInputCoverage",
            "callEffectCoverage",
            "callExcludedState",
        }
    ),
    "registerView": frozenset(
        {
            "id",
            "storageValueId",
            "viewName",
            "canonicalRegister",
            "canonicalBitWidth",
            "bitOffset",
            "bitWidth",
            "readTransform",
            "writeTransform",
        }
    ),
    "registerVersion": frozenset(
        {
            "id",
            "canonicalRegister",
            "bitWidth",
            "kind",
            "definingPcodeOpId",
            "definingRegisterPhiId",
            "writeViewId",
            "writeTransform",
            "sourceRange",
        }
    ),
    "registerBinding": frozenset(
        {"id", "pcodeOpId", "reads", "write", "callClobberRegisterVersionIds"}
    ),
    "registerRead": frozenset(
        {
            "operandIndex",
            "storageValueId",
            "registerViewId",
            "canonicalRegister",
            "inputRegisterVersionId",
            "readTransform",
        }
    ),
    "registerWrite": frozenset(
        {
            "storageValueId",
            "registerViewId",
            "canonicalRegister",
            "outputRegisterVersionId",
            "writeTransform",
        }
    ),
    "registerPhi": frozenset(
        {"id", "blockId", "canonicalRegister", "outputRegisterVersionId", "incoming", "isTrivial"}
    ),
    "registerPhiIncoming": frozenset(
        {"sourceKind", "sourceBlockId", "edgeId", "registerVersionId"}
    ),
    "callRegisterEffect": frozenset(
        {
            "id",
            "pcodeOpId",
            "callKind",
            "callingConvention",
            "coverage",
            "inputs",
            "clobbers",
            "sourceRange",
        }
    ),
    "callRegisterInput": frozenset(
        {
            "registerName",
            "registerClass",
            "bitOffset",
            "bitWidth",
            "reason",
            "access",
            "inputRegisterVersionId",
        }
    ),
    "callRegisterClobber": frozenset(
        {"registerName", "registerClass", "bitOffset", "bitWidth", "reason", "outputRegisterVersionId"}
    ),
    "warning": frozenset({"code", "message"}),
    "resourceUsage": frozenset(
        {
            "mappedByteCount",
            "effectiveMappedByteCount",
            "functionByteCount",
            "effectiveFunctionByteCount",
            "appliedPatchCount",
            "unmappedAddressMetadataCount",
            "instructionCount",
            "valueCount",
            "pcodeOpCount",
            "basicBlockCount",
            "edgeCount",
            "callCount",
            "ssaValueCount",
            "ssaBindingCount",
            "phiCount",
            "heritageUseCount",
            "memoryVersionCount",
            "memoryPhiCount",
            "memoryEffectCount",
            "registerViewCount",
            "registerVersionCount",
            "registerBindingCount",
            "registerPhiCount",
            "callRegisterEffectCount",
            "callRegisterInputSliceCount",
            "callRegisterClobberSliceCount",
        }
    ),
}

class ResultValidationError(ValueError):
    """A closed structured result violates the DCP-03 semantic contract."""


def _fail(message: str) -> None:
    raise ResultValidationError(message)


def _zip_equal_length(
    left: Sequence[_LeftValue],
    right: Sequence[_RightValue],
    *,
    mismatch_message: str,
) -> Iterator[tuple[_LeftValue, _RightValue]]:
    """Pair two closed sequences without relying on Python 3.10's zip strict flag."""

    if len(left) != len(right):
        _fail(mismatch_message)
    return zip(left, right)


def _mapping(value: object, label: str) -> Mapping[str, Any]:
    if not isinstance(value, Mapping):
        _fail(f"{label} must be an object")
    return value


def _closed_mapping(value: object, label: str, shape: str) -> Mapping[str, Any]:
    item = _mapping(value, label)
    expected = _OBJECT_FIELDS[shape]
    if set(item) != expected:
        missing = sorted(expected - set(item))
        extra = sorted(set(item) - expected)
        detail = missing or extra
        qualifier = "missing" if missing else "unknown"
        _fail(f"{label} has {qualifier} fields: {', '.join(detail)}")
    return item


def _array(value: object, label: str) -> list[Any]:
    if not isinstance(value, list):
        _fail(f"{label} must be an array")
    return value


def _index(
    items: Sequence[object],
    *,
    label: str,
    pattern: re.Pattern[str],
    shape: str,
    identifier_key: str = "id",
    require_consecutive: bool = True,
) -> dict[str, Mapping[str, Any]]:
    output: dict[str, Mapping[str, Any]] = {}
    identifiers: list[str] = []
    for raw in items:
        item = _closed_mapping(raw, label, shape)
        identifier = item.get(identifier_key)
        if not isinstance(identifier, str) or pattern.fullmatch(identifier) is None:
            _fail(f"{label} has an invalid identifier")
        if identifier in output:
            _fail(f"{label} identifiers must be unique")
        output[identifier] = item
        identifiers.append(identifier)
    if require_consecutive and identifiers:
        prefix_match = re.match(r"^([A-Za-z]+)", identifiers[0])
        if prefix_match is not None:
            prefix = prefix_match.group(1)
            expected = [f"{prefix}{index:06d}" for index in range(len(identifiers))]
            if identifiers != expected:
                _fail(f"{label} identifiers must be consecutive and ordered")
    return output


def _source_range(
    value: object,
    *,
    image_id: str,
    function_start: int,
    function_end: int,
    label: str,
) -> tuple[int, int]:
    item = _mapping(value, label)
    if set(item) != {"imageId", "startAddress", "endAddressExclusive"}:
        _fail(f"{label} has an invalid shape")
    if item.get("imageId") != image_id:
        _fail(f"{label} is not image-qualified to the result image")
    try:
        start = parse_address(item.get("startAddress"), f"{label}.startAddress")
        end = parse_address(item.get("endAddressExclusive"), f"{label}.endAddressExclusive")
    except ValueError as error:
        _fail(str(error))
    if not function_start <= start < end <= function_end:
        _fail(f"{label} falls outside the function range")
    return start, end


def _expected_paths(
    block: Mapping[str, Any],
    *,
    function_start: int,
    edges: Mapping[str, Mapping[str, Any]],
) -> list[dict[str, object]]:
    paths: list[dict[str, object]] = []
    if parse_address(block.get("startAddress"), "block.startAddress") == function_start:
        paths.append({"sourceKind": "functionEntry", "sourceBlockId": None, "edgeId": None})
    predecessor_ids = _array(block.get("predecessorEdgeIds"), "block.predecessorEdgeIds")
    for edge_id in predecessor_ids:
        edge = edges.get(edge_id)
        if edge is None or edge.get("targetBlockId") != block.get("id"):
            _fail("block predecessor edge is inconsistent")
        paths.append(
            {
                "sourceKind": "block",
                "sourceBlockId": edge.get("sourceBlockId"),
                "edgeId": edge_id,
            }
        )
    return paths



def _image_source_range(
    value: object,
    *,
    image_id: str,
    label: str,
) -> tuple[int, int]:
    item = _mapping(value, label)
    if set(item) != {"imageId", "startAddress", "endAddressExclusive"}:
        _fail(f"{label} has an invalid shape")
    if item.get("imageId") != image_id:
        _fail(f"{label} is not image-qualified to the result image")
    try:
        start = parse_address(item.get("startAddress"), f"{label}.startAddress")
        end = parse_address(
            item.get("endAddressExclusive"),
            f"{label}.endAddressExclusive",
        )
    except ValueError as error:
        _fail(str(error))
    if start >= end:
        _fail(f"{label} is empty or inverted")
    return start, end


def _validate_load_image(
    value: object,
    *,
    image_id: str,
    memory_regions: Sequence[Mapping[str, Any]],
) -> dict[str, object]:
    load_image = _closed_mapping(value, "loadImage", "loadImage")
    model = _closed_mapping(load_image.get("model"), "loadImage.model", "loadImageModel")
    if dict(model) != LOAD_IMAGE_MODEL:
        _fail("loadImage.model is not the frozen DCP-03B2 model")

    effective_regions_raw = _array(
        load_image.get("memoryRegions"),
        "loadImage.memoryRegions",
    )
    if len(effective_regions_raw) != len(memory_regions):
        _fail("loadImage memory regions do not match the image authority")

    parsed_regions: list[tuple[int, int, Mapping[str, Any]]] = []
    for index, raw_region in enumerate(effective_regions_raw):
        region = _closed_mapping(
            raw_region,
            "effective memory region",
            "effectiveMemoryRegion",
        )
        authority = memory_regions[index]
        expected_identity = {
            "name": authority.get("name"),
            "startAddress": authority.get("startAddress"),
            "endAddressExclusive": authority.get("endAddressExclusive"),
            "permissions": authority.get("permissions"),
            "byteCount": authority.get("byteCount"),
            "rawSha256": authority.get("sha256"),
        }
        if any(region.get(key) != expected for key, expected in expected_identity.items()):
            _fail("loadImage memory region does not match the image byte authority")
        effective_digest = region.get("effectiveSha256")
        if not isinstance(effective_digest, str) or _SHA256.fullmatch(effective_digest) is None:
            _fail("loadImage effective memory-region hash is invalid")
        patch_ids = _array(
            region.get("appliedPatchIds"),
            "effectiveMemoryRegion.appliedPatchIds",
        )
        if len(patch_ids) != len(set(patch_ids)) or any(
            not isinstance(identifier, str)
            or _ID_PATTERNS["loadImagePatch"].fullmatch(identifier) is None
            for identifier in patch_ids
        ):
            _fail("effective memory-region patch identifiers are invalid or duplicated")
        try:
            start = parse_address(region.get("startAddress"), "effectiveMemoryRegion.startAddress")
            end = parse_address(
                region.get("endAddressExclusive"),
                "effectiveMemoryRegion.endAddressExclusive",
            )
        except ValueError as error:
            _fail(str(error))
        parsed_regions.append((start, end, region))

    patches_raw = _array(load_image.get("patches"), "loadImage.patches")
    patches = _index(
        patches_raw,
        label="load-image patch",
        pattern=_ID_PATTERNS["loadImagePatch"],
        shape="loadImagePatch",
    )
    expected_patch_ids_by_region: list[list[str]] = [
        [] for _ in effective_regions_raw
    ]
    previous_end = -1
    authenticated_pointer_patch_count = 0
    encoding_by_relocation_kind = {
        "ARM64_RELOC_UNSIGNED": "littleEndianUnsigned64",
        "ARM64_RELOC_BRANCH26": "aarch64Branch26",
        "ARM64_RELOC_PAGE21": "aarch64AdrpPage21",
        "ARM64_RELOC_GOT_LOAD_PAGE21": "aarch64AdrpPage21",
        "ARM64_RELOC_TLVP_LOAD_PAGE21": "aarch64AdrpPage21",
    }
    allowed_pageoff_encodings = {
        "aarch64AddImmediatePageOffset12",
        "aarch64UnsignedLoadStorePageOffset12",
    }
    patch_ranges: list[tuple[int, int, str]] = []
    for patch_id, patch in patches.items():
        source_kind = patch.get("sourceKind")
        source_index = patch.get("sourceIndex")
        width = patch.get("width")
        kind = patch.get("kind")
        encoding = patch.get("encoding")
        if (
            source_kind not in {"relocation", "fixup"}
            or type(source_index) is not int
            or source_index < 0
            or width not in {4, 8}
            or not isinstance(kind, str)
            or _IDENTIFIER.fullmatch(kind) is None
            or not isinstance(encoding, str)
        ):
            _fail("load-image patch identity is invalid")
        try:
            address = parse_address(patch.get("address"), "loadImagePatch.address")
            target_address = parse_address(
                patch.get("targetAddress"),
                "loadImagePatch.targetAddress",
            )
        except ValueError as error:
            _fail(str(error))
        patch_end = address + width
        if address < previous_end:
            _fail("load-image patches overlap or are out of address order")
        previous_end = patch_end
        containing = [
            index
            for index, (start, end, _) in enumerate(parsed_regions)
            if start <= address and patch_end <= end
        ]
        intersecting = [
            index
            for index, (start, end, _) in enumerate(parsed_regions)
            if address < end and start < patch_end
        ]
        if len(containing) != 1 or intersecting != containing:
            _fail("load-image patch is not fully owned by exactly one memory region")
        region_index = containing[0]
        expected_patch_ids_by_region[region_index].append(patch_id)
        patch_ranges.append((address, patch_end, patch_id))

        source_start, source_end = _image_source_range(
            patch.get("sourceRange"),
            image_id=image_id,
            label="loadImagePatch.sourceRange",
        )
        if (source_start, source_end) != (address, patch_end):
            _fail("load-image patch sourceRange does not match its address and width")

        original = patch.get("originalBytesHex")
        effective = patch.get("effectiveBytesHex")
        if (
            not isinstance(original, str)
            or not isinstance(effective, str)
            or len(original) != width * 2
            or len(effective) != width * 2
            or re.fullmatch(r"(?:[0-9a-f]{2})+", original) is None
            or re.fullmatch(r"(?:[0-9a-f]{2})+", effective) is None
        ):
            _fail("load-image patch bytes are invalid")

        symbol = patch.get("symbol")
        addend = patch.get("addend")
        authenticated = patch.get("authenticated")
        key = patch.get("key")
        diversity = patch.get("diversity")
        if source_kind == "relocation":
            if kind not in SUPPORTED_RELOCATION_KINDS:
                _fail("load-image patch uses an unsupported relocation kind")
            expected_width = 8 if kind == "ARM64_RELOC_UNSIGNED" else 4
            if width != expected_width:
                _fail("load-image relocation patch width is inconsistent")
            if kind in encoding_by_relocation_kind:
                if encoding != encoding_by_relocation_kind[kind]:
                    _fail("load-image relocation encoding is inconsistent")
            elif encoding not in allowed_pageoff_encodings:
                _fail("load-image PAGEOFF12 encoding is inconsistent")
            if (
                (symbol is not None and not isinstance(symbol, str))
                or type(addend) is not int
                or authenticated is not None
                or key is not None
                or diversity is not None
            ):
                _fail("load-image relocation provenance is invalid")
            try:
                replacement, derived_encoding = encode_relocation_replacement(
                    kind=kind,
                    address=address,
                    target_address=target_address,
                    original=bytes.fromhex(original),
                )
            except EffectiveLoadImageError as error:
                _fail(f"load-image relocation patch bytes are invalid: {error}")
            if replacement.hex() != effective or derived_encoding != encoding:
                _fail(
                    "load-image relocation effective bytes do not encode the "
                    "claimed target"
                )
        else:
            if kind not in SUPPORTED_FIXUP_KINDS or width != 8:
                _fail("load-image patch uses an unsupported fixup kind or width")
            if encoding != "normalizedPointer64" or symbol is not None or addend is not None:
                _fail("load-image fixup provenance or encoding is invalid")
            kind_is_authenticated = kind in {
                "DYLD_CHAINED_AUTH_REBASE64",
                "DYLD_CHAINED_AUTH_BIND64",
            }
            if authenticated is not kind_is_authenticated:
                _fail("load-image fixup authentication state is inconsistent")
            if kind_is_authenticated:
                if key not in {"ia", "ib", "da", "db"} or type(diversity) is not int:
                    _fail("authenticated load-image fixup evidence is incomplete")
                authenticated_pointer_patch_count += 1
            elif key is not None or diversity is not None:
                _fail("unauthenticated load-image fixup has authentication evidence")
            if effective != target_address.to_bytes(8, "little").hex():
                _fail(
                    "load-image fixup effective bytes do not encode the claimed target"
                )

    for index, (_, _, region) in enumerate(parsed_regions):
        if region.get("appliedPatchIds") != expected_patch_ids_by_region[index]:
            _fail("effective memory-region patch ownership is inconsistent")
        if not expected_patch_ids_by_region[index] and (
            region.get("rawSha256") != region.get("effectiveSha256")
        ):
            _fail("unpatched effective memory-region hash must equal its raw hash")

    unmapped_raw = _array(
        load_image.get("unmappedEvidence"),
        "loadImage.unmappedEvidence",
    )
    unmapped_order: list[tuple[int, int, int]] = []
    for raw_item in unmapped_raw:
        item = _closed_mapping(
            raw_item,
            "unmapped address metadata",
            "unmappedAddressMetadata",
        )
        source_kind = item.get("sourceKind")
        source_index = item.get("sourceIndex")
        kind = item.get("kind")
        if (
            source_kind not in {"relocation", "fixup"}
            or type(source_index) is not int
            or source_index < 0
            or not isinstance(kind, str)
            or _IDENTIFIER.fullmatch(kind) is None
            or item.get("reason") != "outsideSuppliedMemory"
        ):
            _fail("unmapped address metadata record is invalid")
        try:
            address = parse_address(item.get("address"), "unmappedAddressMetadata.address")
        except ValueError as error:
            _fail(str(error))
        if any(start <= address < end for start, end, _ in parsed_regions):
            _fail("unmapped address metadata points into supplied memory")
        unmapped_order.append(
            (address, 0 if source_kind == "relocation" else 1, source_index)
        )
    if unmapped_order != sorted(unmapped_order):
        _fail("unmapped address metadata must be deterministically ordered")

    return {
        "patches": patches,
        "patchRanges": patch_ranges,
        "effectiveMappedByteCount": sum(
            int(region[2]["byteCount"]) for region in parsed_regions
        ),
        "appliedPatchCount": len(patches),
        "unmappedAddressMetadataCount": len(unmapped_raw),
        "authenticatedPointerPatchCount": authenticated_pointer_patch_count,
        "unmappedEvidence": [dict(item) for item in unmapped_raw],
    }


def _validate_load_image_evidence(
    load_image_validation: Mapping[str, object],
    *,
    evidence_symbols: Sequence[object],
    evidence_relocations: Sequence[object],
    evidence_fixups: Sequence[object],
) -> None:
    """Bind every effective-memory record to exactly one evidence input.

    This check is deliberately independent of the original request.  The
    supervisor performs the stronger request-derived reconstruction when the
    request is available, but a stored or transported structured result must
    remain internally self-authenticating enough that source indices cannot be
    redirected to unrelated evidence records.
    """

    symbol_addresses_by_name: dict[str, set[int]] = {}
    for raw_symbol in evidence_symbols:
        symbol = _mapping(raw_symbol, "evidence symbol")
        name = symbol.get("name")
        if not isinstance(name, str):
            _fail("evidence symbol name is invalid")
        try:
            address = parse_address(symbol.get("address"), "symbol.address")
        except ValueError as error:
            _fail(str(error))
        symbol_addresses_by_name.setdefault(name, set()).add(address)

    consumed: set[tuple[str, int]] = set()
    patches = _mapping(load_image_validation.get("patches"), "load-image patches")
    for patch_id, raw_patch in patches.items():
        patch = _mapping(raw_patch, f"load-image patch {patch_id}")
        source_kind = patch.get("sourceKind")
        source_index = patch.get("sourceIndex")
        if type(source_index) is not int:
            _fail("load-image patch sourceIndex is invalid")
        source_key = (str(source_kind), source_index)
        if source_key in consumed:
            _fail("load-image evidence source is referenced more than once")
        consumed.add(source_key)

        if source_kind == "relocation":
            if not 0 <= source_index < len(evidence_relocations):
                _fail("load-image patch references an unknown relocation evidence record")
            relocation = _mapping(
                evidence_relocations[source_index],
                f"evidence relocation {source_index}",
            )
            if (
                patch.get("address") != relocation.get("address")
                or patch.get("kind") != relocation.get("kind")
                or patch.get("symbol") != relocation.get("symbol")
                or patch.get("addend") != relocation.get("addend")
            ):
                _fail("load-image patch does not match its relocation evidence record")

            target_value = relocation.get("targetAddress")
            target_address: int | None = None
            if target_value is not None:
                try:
                    target_address = parse_address(
                        target_value,
                        "relocation.targetAddress",
                    )
                except ValueError as error:
                    _fail(str(error))
            symbol_name = relocation.get("symbol")
            symbol_address: int | None = None
            if symbol_name is not None:
                addresses = symbol_addresses_by_name.get(str(symbol_name), set())
                if not addresses:
                    _fail("load-image relocation symbol has no evidence match")
                if len(addresses) != 1:
                    _fail("load-image relocation symbol evidence is ambiguous")
                symbol_address = next(iter(addresses))
            if target_address is None and symbol_address is None:
                _fail("load-image relocation evidence has no target")
            if (
                target_address is not None
                and symbol_address is not None
                and target_address != symbol_address
            ):
                _fail("load-image relocation target contradicts symbol evidence")
            base = target_address if target_address is not None else symbol_address
            assert base is not None
            addend = relocation.get("addend")
            if type(addend) is not int:
                _fail("load-image relocation addend is invalid")
            resolved = base + addend
            if not 0 <= resolved <= UINT64_MAX:
                _fail("load-image relocation target plus addend overflows")
            if patch.get("targetAddress") != format_address(resolved):
                _fail("load-image patch target does not match relocation evidence")
        elif source_kind == "fixup":
            if not 0 <= source_index < len(evidence_fixups):
                _fail("load-image patch references an unknown fixup evidence record")
            fixup = _mapping(
                evidence_fixups[source_index],
                f"evidence fixup {source_index}",
            )
            if (
                patch.get("address") != fixup.get("address")
                or patch.get("kind") != fixup.get("kind")
                or patch.get("targetAddress") != fixup.get("targetAddress")
                or patch.get("authenticated") != fixup.get("authenticated")
                or patch.get("key") != fixup.get("key")
                or patch.get("diversity") != fixup.get("diversity")
            ):
                _fail("load-image patch does not match its fixup evidence record")
        else:
            _fail("load-image patch sourceKind is invalid")

    unmapped_raw = _array(
        load_image_validation.get("unmappedEvidence"),
        "load-image unmapped evidence",
    )
    for raw_item in unmapped_raw:
        item = _mapping(raw_item, "unmapped address metadata")
        source_kind = item.get("sourceKind")
        source_index = item.get("sourceIndex")
        if type(source_index) is not int:
            _fail("unmapped address metadata sourceIndex is invalid")
        source_key = (str(source_kind), source_index)
        if source_key in consumed:
            _fail("load-image evidence source is referenced more than once")
        consumed.add(source_key)
        if source_kind == "relocation":
            if not 0 <= source_index < len(evidence_relocations):
                _fail("unmapped evidence references an unknown relocation record")
            source = _mapping(
                evidence_relocations[source_index],
                f"evidence relocation {source_index}",
            )
        elif source_kind == "fixup":
            if not 0 <= source_index < len(evidence_fixups):
                _fail("unmapped evidence references an unknown fixup record")
            source = _mapping(
                evidence_fixups[source_index],
                f"evidence fixup {source_index}",
            )
        else:
            _fail("unmapped address metadata sourceKind is invalid")
        if item.get("address") != source.get("address") or item.get("kind") != source.get("kind"):
            _fail("unmapped address metadata does not match its evidence record")

    expected = {
        ("relocation", index) for index in range(len(evidence_relocations))
    } | {("fixup", index) for index in range(len(evidence_fixups))}
    if consumed != expected:
        _fail("load-image records do not cover every relocation and fixup evidence input")


def _validate_request_identity(result: Mapping[str, Any], request: AnalysisRequest) -> None:
    if result.get("requestId") != request.request_id:
        _fail("result requestId did not match the request")
    if result.get("requestSha256") != request.request_sha256:
        _fail("result requestSha256 did not match the request")
    engine = _closed_mapping(result.get("engine"), "engine", "engine")
    if engine.get("languageId") != request.language_id:
        _fail("result languageId did not match the request")
    if engine.get("compilerSpecId") != request.compiler_spec_id:
        _fail("result compilerSpecId did not match the request")
    image = _closed_mapping(result.get("image"), "image", "image")
    if image.get("imageId") != request.image_id or image.get("uuid") != request.image_uuid:
        _fail("result image identity did not match the request")
    if image.get("preferredLoadAddress") != format_address(request.preferred_load_address):
        _fail("result preferredLoadAddress did not match the request")
    expected_regions = [region.output() for region in request.memory_regions]
    if image.get("memoryRegions") != expected_regions:
        _fail("result memoryRegions did not match the request authority")
    try:
        expected_load_image = build_effective_load_image(request)
    except EffectiveLoadImageError as error:
        _fail(f"request cannot derive effective memory: {error}")
    if result.get("loadImage") != expected_load_image.output:
        _fail(
            "result loadImage did not match deterministic request-derived "
            "effective memory or request authority"
        )
    function = _closed_mapping(result.get("function"), "function", "function")
    if function.get("functionId") != request.function_id or function.get("name") != request.function_name:
        _fail("result function identity did not match the request")
    if function.get("entryAddress") != format_address(request.function_entry):
        _fail("result entryAddress did not match the request")
    if function.get("endAddressExclusive") != format_address(request.function_end):
        _fail("result endAddressExclusive did not match the request")
    function_bytes = request.read(
        request.function_entry,
        request.function_end,
        require_executable=True,
    )
    effective_function_bytes = expected_load_image.read(
        request.function_entry,
        request.function_end,
        require_executable=True,
    )
    if (
        function.get("byteCount") != len(function_bytes)
        or function.get("sourceSha256") != bytes_sha256(function_bytes)
        or function.get("effectiveSha256") != bytes_sha256(effective_function_bytes)
        or function.get("appliedPatchIds")
        != expected_load_image.patch_ids_intersecting(
            request.function_entry,
            request.function_end,
        )
    ):
        _fail("result function bytes did not match the request authority")
    expected_evidence = {
        "symbols": [item.output() for item in request.symbols],
        "relocations": [item.output() for item in request.relocations],
        "fixups": [item.output() for item in request.fixups],
        "typeHints": [item.output() for item in request.type_hints],
    }
    if result.get("evidenceInputs") != expected_evidence:
        _fail("result evidenceInputs did not match the request authority")


def validate_result(result: Mapping[str, Any], *, request: AnalysisRequest | None = None) -> None:
    """Validate a successful result, including cross-record semantic invariants."""

    result = _mapping(result, "result")
    if set(result) != _RESULT_FIELDS:
        missing = sorted(_RESULT_FIELDS - set(result))
        extra = sorted(set(result) - _RESULT_FIELDS)
        detail = "missing fields" if missing else "unknown fields"
        _fail(f"result has {detail}: {', '.join(missing or extra)}")
    if type(result.get("schemaVersion")) is not int or result.get("schemaVersion") != RESULT_SCHEMA_VERSION:
        _fail("result has an unsupported schemaVersion")
    if result.get("status") != "ok":
        _fail("result status must be ok")
    if result.get("analysisLevel") != ANALYSIS_LEVEL:
        _fail("result analysisLevel is invalid")
    if result.get("contractCompleteness") != CONTRACT_COMPLETENESS:
        _fail("result contractCompleteness is invalid")
    if result.get("capabilities") != CAPABILITY_TRUTH:
        _fail("result capability truth table is invalid")
    if result.get("analysisSemantics") != ANALYSIS_SEMANTICS:
        _fail("result analysis semantics are invalid")
    request_id = result.get("requestId")
    request_digest = result.get("requestSha256")
    if not isinstance(request_id, str) or _IDENTIFIER.fullmatch(request_id) is None:
        _fail("result requestId is invalid")
    if not isinstance(request_digest, str) or _SHA256.fullmatch(request_digest) is None:
        _fail("result requestSha256 is invalid")

    engine = _closed_mapping(result.get("engine"), "engine", "engine")
    expected_engine = {
        "backend": ENGINE_BACKEND_ID,
        "componentId": ENGINE_COMPONENT_ID,
        "version": ENGINE_VERSION,
        "gitRevision": ENGINE_GIT_REVISION,
    }
    if any(engine.get(key) != value for key, value in expected_engine.items()):
        _fail("result engine identity is invalid")
    if engine.get("languageId") not in ENGINE_LANGUAGE_ALLOWLIST:
        _fail("result engine languageId is unsupported")
    compiler_spec = engine.get("compilerSpecId")
    if not isinstance(compiler_spec, str) or _IDENTIFIER.fullmatch(compiler_spec) is None:
        _fail("result engine compilerSpecId is invalid")
    resources = _array(engine.get("resources"), "engine.resources")
    if len(resources) < ENGINE_MINIMUM_RESOURCE_COUNT:
        _fail("result engine resources are incomplete")
    resource_names: list[str] = []
    for raw_resource in resources:
        resource = _closed_mapping(raw_resource, "engine resource", "engineResource")
        name = resource.get("name")
        byte_count = resource.get("byteCount")
        digest = resource.get("sha256")
        if (
            not isinstance(name, str)
            or not 1 <= len(name) <= 4096
            or _ENGINE_RESOURCE_NAME.fullmatch(name) is None
            or type(byte_count) is not int
            or byte_count < 1
            or not isinstance(digest, str)
            or _SHA256.fullmatch(digest) is None
        ):
            _fail("result engine resource is invalid")
        resource_names.append(name)
    if resource_names != sorted(set(resource_names)):
        _fail("result engine resources must have unique sorted names")

    image = _closed_mapping(result.get("image"), "image", "image")
    image_id = image.get("imageId")
    if not isinstance(image_id, str) or _IDENTIFIER.fullmatch(image_id) is None:
        _fail("image imageId is invalid")
    uuid = image.get("uuid")
    if not isinstance(uuid, str) or _UUID.fullmatch(uuid) is None:
        _fail("image uuid is invalid")
    try:
        parse_address(image.get("preferredLoadAddress"), "image.preferredLoadAddress")
    except ValueError as error:
        _fail(str(error))
    memory_regions = _array(image.get("memoryRegions"), "image.memoryRegions")
    if not memory_regions:
        _fail("image must contain at least one memory region")
    previous_region_end = -1
    mapped_byte_count = 0
    validated_regions: list[tuple[int, int, str]] = []
    for raw_region in memory_regions:
        region = _closed_mapping(raw_region, "memory region", "memoryRegion")
        try:
            region_start = parse_address(region.get("startAddress"), "memoryRegion.startAddress")
            region_end = parse_address(region.get("endAddressExclusive"), "memoryRegion.endAddressExclusive")
        except ValueError as error:
            _fail(str(error))
        byte_count = region.get("byteCount")
        permissions = region.get("permissions")
        digest = region.get("sha256")
        if (
            region_start < previous_region_end
            or region_end <= region_start
            or type(byte_count) is not int
            or not 1 <= byte_count <= 1024 * 1024
            or byte_count != region_end - region_start
            or not isinstance(permissions, str)
            or _PERMISSIONS.fullmatch(permissions) is None
            or not isinstance(digest, str)
            or _SHA256.fullmatch(digest) is None
        ):
            _fail("result memory region is invalid or out of order")
        name = region.get("name")
        if not isinstance(name, str) or not 1 <= len(name) <= 256:
            _fail("result memory region name is invalid")
        previous_region_end = region_end
        mapped_byte_count += byte_count
        validated_regions.append((region_start, region_end, permissions))

    load_image_validation = _validate_load_image(
        result.get("loadImage"),
        image_id=image_id,
        memory_regions=[_mapping(item, "memory region") for item in memory_regions],
    )

    function = _closed_mapping(result.get("function"), "function", "function")
    try:
        function_start = parse_address(function.get("entryAddress"), "function.entryAddress")
        function_end = parse_address(function.get("endAddressExclusive"), "function.endAddressExclusive")
    except ValueError as error:
        _fail(str(error))
    if function_start >= function_end:
        _fail("function range is empty or inverted")
    function_id = function.get("functionId")
    function_name = function.get("name")
    function_byte_count = function.get("byteCount")
    function_digest = function.get("sourceSha256")
    effective_function_digest = function.get("effectiveSha256")
    function_patch_ids = _array(
        function.get("appliedPatchIds"),
        "function.appliedPatchIds",
    )
    if (
        not isinstance(function_id, str)
        or _IDENTIFIER.fullmatch(function_id) is None
        or not isinstance(function_name, str)
        or not 1 <= len(function_name) <= 1024
        or type(function_byte_count) is not int
        or not 4 <= function_byte_count <= 1024 * 1024
        or not isinstance(function_digest, str)
        or _SHA256.fullmatch(function_digest) is None
        or not isinstance(effective_function_digest, str)
        or _SHA256.fullmatch(effective_function_digest) is None
        or function_byte_count != function_end - function_start
        or len(function_patch_ids) != len(set(function_patch_ids))
        or any(
            not isinstance(identifier, str)
            or identifier not in load_image_validation["patches"]
            for identifier in function_patch_ids
        )
    ):
        _fail("function identity or byte metadata is invalid")
    if not any(
        region_start <= function_start
        and function_end <= region_end
        and permissions[2] == "x"
        for region_start, region_end, permissions in validated_regions
    ):
        _fail("function range is not fully contained in one executable memory region")
    expected_function_patch_ids = [
        patch_id
        for start, end, patch_id in load_image_validation["patchRanges"]
        if start < function_end and function_start < end
    ]
    if function_patch_ids != expected_function_patch_ids:
        _fail("function appliedPatchIds do not match effective-memory patches")

    instructions_raw = _array(result.get("instructions"), "instructions")
    if not instructions_raw:
        _fail("result must contain instructions")
    instructions: dict[int, Mapping[str, Any]] = {}
    effective_function_bytes = bytearray()
    instruction_cursor = function_start
    for expected_index, raw in enumerate(instructions_raw):
        instruction = _closed_mapping(raw, "instruction", "instruction")
        index = instruction.get("index")
        if type(index) is not int or index != expected_index:
            _fail("instruction indices must be consecutive and ordered")
        if index in instructions:
            _fail("instruction indices must be unique")
        instructions[index] = instruction
        try:
            address = parse_address(instruction.get("address"), "instruction.address")
        except ValueError as error:
            _fail(str(error))
        if address != instruction_cursor:
            _fail("instructions must cover the declared function contiguously and in address order")
        size = instruction.get("size")
        if type(size) is not int or size <= 0:
            _fail("instruction size is invalid")
        bytes_hex = instruction.get("bytesHex")
        mnemonic = instruction.get("mnemonic")
        body = instruction.get("body")
        pcode_ids = _array(instruction.get("pcodeOpIds"), "instruction.pcodeOpIds")
        if (
            not isinstance(bytes_hex, str)
            or len(bytes_hex) != size * 2
            or re.fullmatch(r"(?:[0-9a-f]{2})+", bytes_hex) is None
            or not isinstance(mnemonic, str)
            or not 1 <= len(mnemonic) <= 256
            or not isinstance(body, str)
            or len(body) > 4096
            or not pcode_ids
            or any(
                not isinstance(item, str)
                or _ID_PATTERNS["operation"].fullmatch(item) is None
                for item in pcode_ids
            )
        ):
            _fail("instruction bytes, text, or p-code identifiers are invalid")
        effective_function_bytes.extend(bytes.fromhex(bytes_hex))
        instruction_cursor = address + size
        source_start, source_end = _source_range(
            instruction.get("sourceRange"),
            image_id=image_id,
            function_start=function_start,
            function_end=function_end,
            label="instruction.sourceRange",
        )
        if (source_start, source_end) != (address, address + size):
            _fail("instruction sourceRange does not match its address and size")
    if instruction_cursor != function_end:
        _fail("instructions do not cover the complete declared function range")
    if function.get("byteCount") != len(effective_function_bytes):
        _fail("function byteCount does not match instruction bytes")
    if function.get("effectiveSha256") != bytes_sha256(bytes(effective_function_bytes)):
        _fail("function effectiveSha256 does not match instruction bytes")
    for patch_id in function_patch_ids:
        patch = _mapping(
            load_image_validation["patches"][patch_id],
            f"load-image patch {patch_id}",
        )
        patch_start = parse_address(patch.get("address"), "loadImagePatch.address")
        patch_bytes = bytes.fromhex(str(patch.get("effectiveBytesHex")))
        patch_end = patch_start + len(patch_bytes)
        overlap_start = max(function_start, patch_start)
        overlap_end = min(function_end, patch_end)
        if overlap_start >= overlap_end:
            _fail("function patch identifier does not intersect the function")
        function_slice = bytes(
            effective_function_bytes[
                overlap_start - function_start : overlap_end - function_start
            ]
        )
        patch_slice = patch_bytes[
            overlap_start - patch_start : overlap_end - patch_start
        ]
        if function_slice != patch_slice:
            _fail(
                "function instruction bytes do not contain the effective bytes "
                "of an intersecting load-image patch"
            )

    values_raw = _array(result.get("values"), "values")
    values = _index(values_raw, label="value", pattern=_ID_PATTERNS["value"], shape="value")
    allowed_storage_classes = {"register", "constant", "memory", "temporary", "internal", "composite", "other"}
    instruction_addresses = {
        parse_address(item.get("address"), "instruction.address") for item in instructions.values()
    }
    for raw_value in values.values():
        space = raw_value.get("space")
        size = raw_value.get("size")
        register_name = raw_value.get("registerName")
        scope = raw_value.get("scopeInstructionAddress")
        if (
            not isinstance(space, str)
            or not 1 <= len(space) <= 256
            or type(size) is not int
            or size < 1
            or raw_value.get("storageClass") not in allowed_storage_classes
            or (register_name is not None and (not isinstance(register_name, str) or len(register_name) > 256))
        ):
            _fail("raw storage value is invalid")
        try:
            parse_address(raw_value.get("offset"), "value.offset")
            if scope is not None:
                scope_address = parse_address(scope, "value.scopeInstructionAddress")
                if scope_address not in instruction_addresses:
                    _fail("value scopeInstructionAddress is not an instruction boundary")
        except ValueError as error:
            _fail(str(error))

    operations_raw = _array(result.get("pcodeOps"), "pcodeOps")
    if not operations_raw:
        _fail("result must contain p-code operations")
    operations = _index(operations_raw, label="p-code operation", pattern=_ID_PATTERNS["operation"], shape="pcodeOp")
    operations_for_instruction: dict[int, list[str]] = {index: [] for index in instructions}
    for operation_id, operation in operations.items():
        instruction_index = operation.get("instructionIndex")
        if type(instruction_index) is not int or instruction_index not in instructions:
            _fail("p-code operation references an unknown instruction")
        sequence = operation.get("sequence")
        if type(sequence) is not int or sequence != len(operations_for_instruction[instruction_index]):
            _fail("p-code sequences must be consecutive within each instruction")
        operations_for_instruction[instruction_index].append(operation_id)
        inputs = _array(operation.get("inputs"), "p-code inputs")
        opcode = operation.get("opcode")
        if not isinstance(opcode, str) or _OPCODE.fullmatch(opcode) is None:
            _fail("p-code opcode is invalid")
        if any(not isinstance(value_id, str) or value_id not in values for value_id in inputs):
            _fail("p-code input references an unknown value")
        output = operation.get("output")
        if output is not None and (not isinstance(output, str) or output not in values):
            _fail("p-code output references an unknown value")
        direct_target = operation.get("directTargetAddress")
        if direct_target is not None:
            try:
                parse_address(direct_target, "pcodeOp.directTargetAddress")
            except ValueError as error:
                _fail(str(error))
        source_start, source_end = _source_range(
            operation.get("sourceRange"),
            image_id=image_id,
            function_start=function_start,
            function_end=function_end,
            label="pcodeOp.sourceRange",
        )
        instruction = instructions[instruction_index]
        if (source_start, source_end) != (
            parse_address(instruction.get("address"), "instruction.address"),
            parse_address(instruction["sourceRange"]["endAddressExclusive"], "instruction.sourceRange.end"),
        ):
            _fail("p-code sourceRange does not match its instruction")
    for index, instruction in instructions.items():
        if instruction.get("pcodeOpIds") != operations_for_instruction[index]:
            _fail("instruction pcodeOpIds do not match operation order")

    blocks_raw = _array(result.get("basicBlocks"), "basicBlocks")
    if not blocks_raw:
        _fail("result must contain basic blocks")
    blocks = _index(
        blocks_raw,
        label="basic block",
        pattern=_ID_PATTERNS["block"],
        shape="basicBlock",
        require_consecutive=False,
    )
    instruction_block: dict[int, str] = {}
    previous_block_start: int | None = None
    for block_id, block in blocks.items():
        start = parse_address(block.get("startAddress"), "block.startAddress")
        end = parse_address(block.get("endAddressExclusive"), "block.endAddressExclusive")
        if previous_block_start is not None and start <= previous_block_start:
            _fail("basic blocks must be strictly ordered by start address")
        previous_block_start = start
        if block_id != f"bb_{start:x}" or not function_start <= start < end <= function_end:
            _fail("basic block identity or range is invalid")
        indices = _array(block.get("instructionIndices"), "block.instructionIndices")
        terminator = _closed_mapping(block.get("terminator"), "block.terminator", "terminator")
        terminator_kind = terminator.get("kind")
        terminator_operation_id = terminator.get("pcodeOpId")
        terminator_target = terminator.get("directTargetAddress")
        expected_opcode = {
            "conditionalBranch": "CBRANCH",
            "branch": "BRANCH",
            "indirectBranch": "BRANCHIND",
            "return": "RETURN",
        }.get(terminator_kind)
        allowed_terminators = {
            "fallthrough",
            "functionEnd",
            "conditionalBranch",
            "branch",
            "indirectBranch",
            "return",
        }
        if terminator_kind not in allowed_terminators:
            _fail("basic block terminator kind is invalid")
        if expected_opcode is None:
            if terminator_operation_id is not None or terminator_target is not None:
                _fail("non-p-code block terminator has an invalid definition")
        else:
            if (
                terminator_operation_id not in operations
                or operations[terminator_operation_id].get("opcode") != expected_opcode
            ):
                _fail("basic block terminator does not match its p-code operation")
            if terminator_target != operations[terminator_operation_id].get("directTargetAddress"):
                _fail("basic block terminator target does not match its p-code operation")
        if not indices:
            _fail("basic block must contain instructions")
        if any(type(index) is not int for index in indices):
            _fail("basic block instruction indices must be integers")
        if indices != list(range(indices[0], indices[-1] + 1)):
            _fail("basic block instruction indices must be consecutive and ordered")
        for index in indices:
            if type(index) is not int or index not in instructions:
                _fail("basic block references an unknown instruction")
            if index in instruction_block:
                _fail("instruction belongs to multiple basic blocks")
            instruction_block[index] = block_id
        first = instructions[indices[0]]
        last = instructions[indices[-1]]
        if start != parse_address(first.get("address"), "instruction.address"):
            _fail("basic block start does not match its first instruction")
        if end != parse_address(last["sourceRange"]["endAddressExclusive"], "instruction.sourceRange.end"):
            _fail("basic block end does not match its last instruction")
        if (
            terminator_operation_id is not None
            and operations[terminator_operation_id].get("instructionIndex") != indices[-1]
        ):
            _fail("basic block terminator is not owned by its final instruction")
    if set(instruction_block) != set(instructions):
        _fail("not every instruction belongs to exactly one basic block")

    edges_raw = _array(result.get("edges"), "edges")
    edges = _index(edges_raw, label="edge", pattern=_ID_PATTERNS["edge"], shape="edge")
    expected_incoming: dict[str, list[str]] = {block_id: [] for block_id in blocks}
    expected_outgoing: dict[str, list[str]] = {block_id: [] for block_id in blocks}
    for edge_id, edge in edges.items():
        source = edge.get("sourceBlockId")
        target = edge.get("targetBlockId")
        kind = edge.get("kind")
        if source not in blocks:
            _fail("edge references an unknown source block")
        if target is not None and target not in blocks:
            _fail("edge references an unknown target block")
        if kind not in {"branchTrue", "branchFalse", "branch", "fallthrough", "indirect"}:
            _fail("edge kind is invalid")
        target_address = edge.get("targetAddress")
        if target_address is not None:
            try:
                parse_address(target_address, "edge.targetAddress")
            except ValueError as error:
                _fail(str(error))
        if kind == "indirect":
            if target is not None or target_address is not None:
                _fail("indirect edge must not claim a static target")
        elif target_address is None:
            _fail("direct or fallthrough edge must carry a target address")
        else:
            target_integer = parse_address(target_address, "edge.targetAddress")
            internal_target = next(
                (
                    block_id
                    for block_id, block in blocks.items()
                    if parse_address(block.get("startAddress"), "block.startAddress")
                    == target_integer
                ),
                None,
            )
            if function_start <= target_integer < function_end and internal_target is None:
                _fail("internal edge target is not a basic-block boundary")
            if target != internal_target:
                _fail("edge targetBlockId does not match its targetAddress")
        expected_outgoing[source].append(edge_id)
        if target is not None:
            expected_incoming[target].append(edge_id)
            if target_address != blocks[target].get("startAddress"):
                _fail("internal edge targetAddress does not match its target block")
        pcode_op_id = edge.get("pcodeOpId")
        if pcode_op_id is not None and pcode_op_id not in operations:
            _fail("edge references an unknown p-code operation")
    for block_id, block in blocks.items():
        if block.get("predecessorEdgeIds") != expected_incoming[block_id]:
            _fail("basic block predecessorEdgeIds are inconsistent")
        if block.get("successorEdgeIds") != expected_outgoing[block_id]:
            _fail("basic block successorEdgeIds are inconsistent")

        block_end = parse_address(block.get("endAddressExclusive"), "block.endAddressExclusive")
        terminator = _mapping(block.get("terminator"), "block.terminator")
        terminator_kind = terminator.get("kind")
        terminator_operation_id = terminator.get("pcodeOpId")
        terminator_target = terminator.get("directTargetAddress")
        expected_edges: list[tuple[str, str | None, str | None]] = []
        if terminator_kind == "fallthrough":
            if block_end >= function_end:
                _fail("fallthrough terminator must end before the function boundary")
            expected_edges.append(("fallthrough", format_address(block_end), None))
        elif terminator_kind == "functionEnd":
            if block_end != function_end:
                _fail("functionEnd terminator does not end at the function boundary")
        elif terminator_kind == "conditionalBranch":
            if terminator_target is None:
                _fail("conditional branch terminator must have a direct target")
            expected_edges.append(("branchTrue", terminator_target, terminator_operation_id))
            if block_end < function_end:
                expected_edges.append(
                    ("branchFalse", format_address(block_end), terminator_operation_id)
                )
        elif terminator_kind == "branch":
            if terminator_target is None:
                _fail("branch terminator must have a direct target")
            expected_edges.append(("branch", terminator_target, terminator_operation_id))
        elif terminator_kind == "indirectBranch":
            expected_edges.append(("indirect", None, terminator_operation_id))
        elif terminator_kind != "return":
            _fail("basic block terminator kind is invalid")

        actual_edges = [edges[edge_id] for edge_id in block.get("successorEdgeIds", [])]
        for actual, expected in _zip_equal_length(
            actual_edges,
            expected_edges,
            mismatch_message="basic block successor edges do not match its terminator",
        ):
            expected_kind, expected_target, expected_operation = expected
            if (
                actual.get("kind") != expected_kind
                or actual.get("targetAddress") != expected_target
                or actual.get("pcodeOpId") != expected_operation
            ):
                _fail("basic block successor edge semantics do not match its terminator")

    calls_raw = _array(result.get("calls"), "calls")
    calls = _index(calls_raw, label="call", pattern=_ID_PATTERNS["call"], shape="call")
    call_by_operation: dict[str, Mapping[str, Any]] = {}
    for call in calls.values():
        operation_id = call.get("pcodeOpId")
        if (
            operation_id not in operations
            or operations[operation_id].get("opcode") not in {"CALL", "CALLIND"}
            or operation_id in call_by_operation
        ):
            _fail("call does not reference a call p-code operation")
        operation = operations[operation_id]
        direct_target = operation.get("directTargetAddress")
        expected_kind = "direct" if direct_target is not None else "indirect"
        if call.get("kind") != expected_kind or call.get("targetAddress") != direct_target:
            _fail("call kind or target does not match its p-code operation")
        source_start, source_end = _source_range(
            call.get("sourceRange"),
            image_id=image_id,
            function_start=function_start,
            function_end=function_end,
            label="call.sourceRange",
        )
        operation_source = _mapping(operation.get("sourceRange"), "pcodeOp.sourceRange")
        if (source_start, source_end) != (
            parse_address(operation_source.get("startAddress"), "pcodeOp.sourceRange.startAddress"),
            parse_address(
                operation_source.get("endAddressExclusive"),
                "pcodeOp.sourceRange.endAddressExclusive",
            ),
        ):
            _fail("call sourceRange does not match its p-code operation")
        target_symbol = call.get("targetSymbol")
        if target_symbol is not None:
            symbol = _closed_mapping(target_symbol, "call.targetSymbol", "symbol")
            if expected_kind != "direct":
                _fail("indirect call cannot have a statically resolved targetSymbol")
            if symbol.get("imageId") != image_id or symbol.get("address") != direct_target:
                _fail("call targetSymbol does not match the direct target")
            name = symbol.get("name")
            kind = symbol.get("kind")
            if (
                not isinstance(name, str)
                or not 1 <= len(name) <= 1024
                or not isinstance(kind, str)
                or _IDENTIFIER.fullmatch(kind) is None
            ):
                _fail("call targetSymbol is invalid")
        if request is not None and direct_target is not None:
            expected_symbol = request.symbol_at(parse_address(direct_target, "call.targetAddress"))
            expected_symbol_output = None if expected_symbol is None else expected_symbol.output()
            if target_symbol != expected_symbol_output:
                _fail("call targetSymbol did not match request symbol evidence")
        call_by_operation[operation_id] = call
    expected_call_operations = {
        operation_id
        for operation_id, operation in operations.items()
        if operation.get("opcode") in {"CALL", "CALLIND"}
    }
    if set(call_by_operation) != expected_call_operations:
        _fail("calls must cover every call p-code operation exactly once")

    evidence = _closed_mapping(result.get("evidenceInputs"), "evidenceInputs", "evidenceInputs")
    evidence_symbols = _array(evidence.get("symbols"), "evidenceInputs.symbols")
    evidence_relocations = _array(evidence.get("relocations"), "evidenceInputs.relocations")
    evidence_fixups = _array(evidence.get("fixups"), "evidenceInputs.fixups")
    evidence_type_hints = _array(evidence.get("typeHints"), "evidenceInputs.typeHints")
    for raw_symbol in evidence_symbols:
        symbol = _closed_mapping(raw_symbol, "evidence symbol", "symbol")
        try:
            parse_address(symbol.get("address"), "symbol.address")
        except ValueError as error:
            _fail(str(error))
        name = symbol.get("name")
        kind = symbol.get("kind")
        if (
            symbol.get("imageId") != image_id
            or not isinstance(name, str)
            or not 1 <= len(name) <= 1024
            or not isinstance(kind, str)
            or _IDENTIFIER.fullmatch(kind) is None
        ):
            _fail("evidence symbol is invalid")
    for raw_relocation in evidence_relocations:
        relocation = _closed_mapping(raw_relocation, "evidence relocation", "relocation")
        try:
            parse_address(relocation.get("address"), "relocation.address")
            if relocation.get("targetAddress") is not None:
                parse_address(relocation.get("targetAddress"), "relocation.targetAddress")
        except ValueError as error:
            _fail(str(error))
        addend = relocation.get("addend")
        symbol_name = relocation.get("symbol")
        kind = relocation.get("kind")
        if (
            type(addend) is not int
            or not -(1 << 63) <= addend <= (1 << 63) - 1
            or not isinstance(kind, str)
            or _IDENTIFIER.fullmatch(kind) is None
            or (symbol_name is not None and (not isinstance(symbol_name, str) or len(symbol_name) > 1024))
        ):
            _fail("evidence relocation is invalid")
    for raw_fixup in evidence_fixups:
        fixup = _closed_mapping(raw_fixup, "evidence fixup", "fixup")
        try:
            parse_address(fixup.get("address"), "fixup.address")
            if fixup.get("targetAddress") is not None:
                parse_address(fixup.get("targetAddress"), "fixup.targetAddress")
        except ValueError as error:
            _fail(str(error))
        authenticated = fixup.get("authenticated")
        key = fixup.get("key")
        diversity = fixup.get("diversity")
        kind = fixup.get("kind")
        if (
            type(authenticated) is not bool
            or not isinstance(kind, str)
            or _IDENTIFIER.fullmatch(kind) is None
            or (key is not None and (not isinstance(key, str) or _IDENTIFIER.fullmatch(key) is None))
            or (diversity is not None and (type(diversity) is not int or not 0 <= diversity <= 0xFFFF))
            or (not authenticated and (key is not None or diversity is not None))
        ):
            _fail("evidence fixup is invalid")
    for raw_hint in evidence_type_hints:
        hint = _closed_mapping(raw_hint, "evidence type hint", "typeHint")
        try:
            parse_address(hint.get("address"), "typeHint.address")
        except ValueError as error:
            _fail(str(error))
        subject_kind = hint.get("subjectKind")
        type_name = hint.get("typeName")
        source = hint.get("source")
        if (
            not isinstance(subject_kind, str)
            or _IDENTIFIER.fullmatch(subject_kind) is None
            or not isinstance(type_name, str)
            or not 1 <= len(type_name) <= 4096
            or hint.get("confidence") not in {"asserted", "high", "medium", "low"}
            or not isinstance(source, str)
            or _IDENTIFIER.fullmatch(source) is None
        ):
            _fail("evidence type hint is invalid")

    _validate_load_image_evidence(
        load_image_validation,
        evidence_symbols=evidence_symbols,
        evidence_relocations=evidence_relocations,
        evidence_fixups=evidence_fixups,
    )

    if request is not None:
        _validate_request_identity(result, request)

    ssa_values_raw = _array(result.get("ssaValues"), "ssaValues")
    ssa_values = _index(ssa_values_raw, label="SSA value", pattern=_ID_PATTERNS["ssa"], shape="ssaValue")
    for ssa_value in ssa_values.values():
        storage_id = ssa_value.get("storageValueId")
        if storage_id not in values:
            _fail("SSA value references unknown storage")
        kind = ssa_value.get("kind")
        defining_op = ssa_value.get("definingPcodeOpId")
        defining_phi = ssa_value.get("definingPhiId")
        source = ssa_value.get("sourceRange")
        if kind in {"entry", "constant", "address", "internal"}:
            if defining_op is not None or defining_phi is not None or source is not None:
                _fail("entry/literal SSA value has an invalid definition")
        elif kind == "operationResult":
            if defining_op not in operations or defining_phi is not None or source is None:
                _fail("operation-result SSA value has an invalid definition")
            _source_range(
                source,
                image_id=image_id,
                function_start=function_start,
                function_end=function_end,
                label="ssaValue.sourceRange",
            )
        elif kind == "phi":
            if not isinstance(defining_phi, str) or defining_op is not None or source is not None:
                _fail("phi SSA value has an invalid definition")
        else:
            _fail("SSA value kind is invalid")

    bindings_raw = _array(result.get("ssaBindings"), "ssaBindings")
    bindings = _index(bindings_raw, label="SSA binding", pattern=_ID_PATTERNS["binding"], shape="ssaBinding")
    binding_by_operation: dict[str, Mapping[str, Any]] = {}
    for binding in bindings.values():
        operation_id = binding.get("pcodeOpId")
        if operation_id not in operations or operation_id in binding_by_operation:
            _fail("SSA bindings must map one-to-one to p-code operations")
        input_ids = _array(binding.get("inputSsaValueIds"), "binding.inputSsaValueIds")
        if len(input_ids) != len(operations[operation_id]["inputs"]):
            _fail("SSA binding input count does not match p-code inputs")
        if any(ssa_id not in ssa_values for ssa_id in input_ids):
            _fail("SSA binding references an unknown input SSA value")
        output_id = binding.get("outputSsaValueId")
        raw_output = operations[operation_id].get("output")
        if (output_id is None) != (raw_output is None):
            _fail("SSA binding output presence does not match p-code output")
        if output_id is not None:
            if output_id not in ssa_values:
                _fail("SSA binding references an unknown output SSA value")
            output_value = ssa_values[output_id]
            if (
                output_value.get("kind") != "operationResult"
                or output_value.get("definingPcodeOpId") != operation_id
                or output_value.get("storageValueId") != raw_output
            ):
                _fail("SSA output definition does not match its p-code operation")
        binding_by_operation[operation_id] = binding
    if set(binding_by_operation) != set(operations):
        _fail("every p-code operation must have one SSA binding")

    heritage_raw = _array(result.get("heritage"), "heritage")
    heritage = _index(heritage_raw, label="heritage use", pattern=_ID_PATTERNS["use"], shape="heritageUse")
    heritage_keys: set[tuple[str, int]] = set()
    for use in heritage.values():
        operation_id = use.get("pcodeOpId")
        operand_index = use.get("operandIndex")
        if operation_id not in operations or type(operand_index) is not int:
            _fail("heritage use references an invalid operation or operand")
        inputs = operations[operation_id]["inputs"]
        if not 0 <= operand_index < len(inputs):
            _fail("heritage operandIndex is out of range")
        key = (operation_id, operand_index)
        if key in heritage_keys:
            _fail("heritage operand mappings must be unique")
        heritage_keys.add(key)
        if use.get("storageValueId") != inputs[operand_index]:
            _fail("heritage storage does not match the p-code operand")
        binding_ssa = binding_by_operation[operation_id]["inputSsaValueIds"][operand_index]
        if use.get("ssaValueId") != binding_ssa:
            _fail("heritage SSA value does not match the operation binding")
        _source_range(
            use.get("sourceRange"),
            image_id=image_id,
            function_start=function_start,
            function_end=function_end,
            label="heritage.sourceRange",
        )
    expected_heritage_keys = {
        (operation_id, index)
        for operation_id, operation in operations.items()
        for index in range(len(operation["inputs"]))
    }
    if heritage_keys != expected_heritage_keys:
        _fail("heritage must cover every p-code input exactly once")

    phis_raw = _array(result.get("phis"), "phis")
    phis = _index(phis_raw, label="phi", pattern=_ID_PATTERNS["phi"], shape="phi")
    for phi_id, phi in phis.items():
        block_id = phi.get("blockId")
        storage_id = phi.get("storageValueId")
        output_ssa_id = phi.get("outputSsaValueId")
        if block_id not in blocks or storage_id not in values or output_ssa_id not in ssa_values:
            _fail("phi references an unknown block, storage, or SSA value")
        output_ssa = ssa_values[output_ssa_id]
        if (
            output_ssa.get("kind") != "phi"
            or output_ssa.get("definingPhiId") != phi_id
            or output_ssa.get("storageValueId") != storage_id
        ):
            _fail("phi output SSA definition is inconsistent")
        incoming = _array(phi.get("incoming"), "phi.incoming")
        expected_paths = _expected_paths(blocks[block_id], function_start=function_start, edges=edges)
        incoming_ids: list[str] = []
        for actual, expected in _zip_equal_length(
            incoming,
            expected_paths,
            mismatch_message="phi incoming count does not match predecessor paths",
        ):
            actual = _closed_mapping(actual, "phi incoming", "phiIncoming")
            if {key: actual.get(key) for key in expected} != expected:
                _fail("phi incoming predecessor identity is inconsistent")
            ssa_id = actual.get("ssaValueId")
            if ssa_id not in ssa_values or ssa_values[ssa_id].get("storageValueId") != storage_id:
                _fail("phi incoming SSA value has incompatible storage")
            incoming_ids.append(ssa_id)
        if phi.get("isTrivial") is not (bool(incoming_ids) and len(set(incoming_ids)) == 1):
            _fail("phi isTrivial flag is inconsistent")
    phi_definition_ids = {
        item.get("definingPhiId") for item in ssa_values.values() if item.get("kind") == "phi"
    }
    if phi_definition_ids != set(phis):
        _fail("phi SSA definitions and phi records are not one-to-one")

    memory_versions_raw = _array(result.get("memoryVersions"), "memoryVersions")
    memory_versions = _index(
        memory_versions_raw,
        label="memory version",
        pattern=_ID_PATTERNS["memory"],
        shape="memoryVersion",
    )
    entry_memory_ids: list[str] = []
    for memory_id, version in memory_versions.items():
        if version.get("partition") != "unknown":
            _fail("memory version uses an unsupported partition")
        kind = version.get("kind")
        defining_op = version.get("definingPcodeOpId")
        defining_phi = version.get("definingMemoryPhiId")
        source = version.get("sourceRange")
        if kind == "functionEntry":
            entry_memory_ids.append(memory_id)
            if defining_op is not None or defining_phi is not None or source is not None:
                _fail("function-entry memory version has an invalid definition")
        elif kind == "operationResult":
            if defining_op not in operations or defining_phi is not None or source is None:
                _fail("operation memory version has an invalid definition")
            _source_range(
                source,
                image_id=image_id,
                function_start=function_start,
                function_end=function_end,
                label="memoryVersion.sourceRange",
            )
        elif kind == "phi":
            if not isinstance(defining_phi, str) or defining_op is not None or source is not None:
                _fail("phi memory version has an invalid definition")
        else:
            _fail("memory version kind is invalid")
    if len(entry_memory_ids) != 1:
        _fail("MemorySSA must contain exactly one function-entry version")
    memory_entry_id = entry_memory_ids[0]

    memory_phis_raw = _array(result.get("memoryPhis"), "memoryPhis")
    memory_phis = _index(
        memory_phis_raw,
        label="memory phi",
        pattern=_ID_PATTERNS["memoryPhi"],
        shape="memoryPhi",
    )
    memory_phi_by_block: dict[str, Mapping[str, Any]] = {}
    for phi_id, phi in memory_phis.items():
        block_id = phi.get("blockId")
        output_id = phi.get("outputMemoryVersionId")
        if block_id not in blocks or block_id in memory_phi_by_block or output_id not in memory_versions:
            _fail("memory phi references an invalid or duplicate block/output")
        if phi.get("partition") != "unknown":
            _fail("memory phi uses an unsupported partition")
        output_version = memory_versions[output_id]
        if output_version.get("kind") != "phi" or output_version.get("definingMemoryPhiId") != phi_id:
            _fail("memory phi output definition is inconsistent")
        expected_paths = _expected_paths(blocks[block_id], function_start=function_start, edges=edges)
        incoming = _array(phi.get("incoming"), "memoryPhi.incoming")
        incoming_ids: list[str] = []
        for actual, expected in _zip_equal_length(
            incoming,
            expected_paths,
            mismatch_message="memory phi incoming count does not match predecessor paths",
        ):
            actual = _closed_mapping(
                actual,
                "memory phi incoming",
                "memoryPhiIncoming",
            )
            if {key: actual.get(key) for key in expected} != expected:
                _fail("memory phi incoming predecessor identity is inconsistent")
            memory_id = actual.get("memoryVersionId")
            if memory_id not in memory_versions:
                _fail("memory phi incoming references an unknown memory version")
            incoming_ids.append(memory_id)
        if phi.get("isTrivial") is not (bool(incoming_ids) and len(set(incoming_ids)) == 1):
            _fail("memory phi isTrivial flag is inconsistent")
        memory_phi_by_block[block_id] = phi
    memory_phi_definition_ids = {
        item.get("definingMemoryPhiId")
        for item in memory_versions.values()
        if item.get("kind") == "phi"
    }
    if memory_phi_definition_ids != set(memory_phis):
        _fail("memory phi definitions and records are not one-to-one")

    memory_effects_raw = _array(result.get("memoryEffects"), "memoryEffects")
    memory_effects = _index(
        memory_effects_raw,
        label="memory effect",
        pattern=_ID_PATTERNS["memoryEffect"],
        shape="memoryEffect",
    )
    memory_effect_by_operation: dict[str, Mapping[str, Any]] = {}
    for effect in memory_effects.values():
        operation_id = effect.get("pcodeOpId")
        if operation_id not in operations or operation_id in memory_effect_by_operation:
            _fail("memory effects must map one-to-one to memory-affecting operations")
        expected_kind = _MEMORY_KIND_BY_OPCODE.get(operations[operation_id].get("opcode"))
        if effect.get("kind") != expected_kind or effect.get("partition") != "unknown":
            _fail("memory effect kind does not match its p-code opcode")
        input_id = effect.get("inputMemoryVersionId")
        output_id = effect.get("outputMemoryVersionId")
        if input_id not in memory_versions:
            _fail("memory effect references an unknown input version")
        if expected_kind == "read":
            if output_id is not None:
                _fail("memory read must not define a new version")
        else:
            if output_id not in memory_versions:
                _fail("memory write/clobber must define a memory version")
            output_version = memory_versions[output_id]
            if (
                output_version.get("kind") != "operationResult"
                or output_version.get("definingPcodeOpId") != operation_id
            ):
                _fail("memory effect output definition is inconsistent")
        _source_range(
            effect.get("sourceRange"),
            image_id=image_id,
            function_start=function_start,
            function_end=function_end,
            label="memoryEffect.sourceRange",
        )
        memory_effect_by_operation[operation_id] = effect
    expected_memory_ops = {
        operation_id
        for operation_id, operation in operations.items()
        if operation.get("opcode") in _MEMORY_KIND_BY_OPCODE
    }
    if set(memory_effect_by_operation) != expected_memory_ops:
        _fail("memory effects must cover every modeled memory operation exactly once")

    operations_by_block: dict[str, list[Mapping[str, Any]]] = {block_id: [] for block_id in blocks}
    for operation in operations.values():
        operations_by_block[instruction_block[operation["instructionIndex"]]].append(operation)

    def first_memory_for_block(block_id: str, previous_out: Mapping[str, str]) -> str:
        phi = memory_phi_by_block.get(block_id)
        if phi is not None:
            return phi["outputMemoryVersionId"]
        paths = _expected_paths(blocks[block_id], function_start=function_start, edges=edges)
        candidates: list[str] = []
        for path in paths:
            if path["sourceKind"] == "functionEntry":
                candidates.append(memory_entry_id)
            else:
                source = path["sourceBlockId"]
                if not isinstance(source, str):
                    raise ResultValidationError(
                        "memory predecessor path is missing its source block"
                    )
                candidates.append(previous_out.get(source, memory_entry_id))
        if not candidates:
            return memory_entry_id
        return candidates[0] if len(set(candidates)) == 1 else memory_entry_id

    def memory_exit(block_id: str, previous_out: Mapping[str, str], *, verify: bool) -> str:
        # The chain is verified only against the converged block states. Checking inside the
        # fixed-point iteration compared recorded inputs with not-yet-propagated entry states and
        # rejected every function whose memory chain crosses a block boundary.
        current = first_memory_for_block(block_id, previous_out)
        for operation in operations_by_block[block_id]:
            effect = memory_effect_by_operation.get(operation["id"])
            if effect is None:
                continue
            if verify and effect.get("inputMemoryVersionId") != current:
                _fail("memory effect input does not follow the block MemorySSA chain")
            output = effect.get("outputMemoryVersionId")
            if output is not None:
                current = output
        return current

    block_order = [item["id"] for item in blocks_raw]
    memory_out = {block_id: memory_entry_id for block_id in block_order}
    for _ in range(max(4, len(block_order) * 2 + 4)):
        next_out = {block_id: memory_exit(block_id, memory_out, verify=False) for block_id in block_order}
        if next_out == memory_out:
            memory_out = next_out
            break
        memory_out = next_out
    else:
        _fail("result MemorySSA did not reach a fixed point")
    for block_id in block_order:
        memory_exit(block_id, memory_out, verify=True)
    for block_id, phi in memory_phi_by_block.items():
        expected_paths = _expected_paths(blocks[block_id], function_start=function_start, edges=edges)
        for actual, path in _zip_equal_length(
            phi["incoming"],
            expected_paths,
            mismatch_message="memory phi incoming count does not match predecessor paths",
        ):
            expected_id = (
                memory_entry_id
                if path["sourceKind"] == "functionEntry"
                else memory_out[path["sourceBlockId"]]
            )
            if actual.get("memoryVersionId") != expected_id:
                _fail("memory phi incoming version does not match predecessor output")

    # Re-derive the complete low-level data-flow contract from the validated raw
    # graph. This is a deterministic translation-validation boundary: a child
    # cannot substitute a merely well-formed but semantically unrelated SSA or
    # MemorySSA graph. The explicit checks above retain precise diagnostics for
    # malformed references; this equality check covers dominance/versioning and
    # phi-placement details as one closed invariant.
    try:
        expected_dataflow = derive_dataflow(
            values=values_raw,
            pcode_ops=operations_raw,
            basic_blocks=blocks_raw,
            edges=edges_raw,
            function_entry=function_start,
        )
    except DataflowDerivationError as error:
        _fail(f"raw result graph cannot be heritage-analyzed: {error}")
    for field in (
        "analysisSemantics",
        "ssaValues",
        "ssaBindings",
        "phis",
        "heritage",
        "memoryVersions",
        "memoryPhis",
        "memoryEffects",
    ):
        if result.get(field) != expected_dataflow[field]:
            _fail(f"{field} does not match deterministic raw-p-code derivation")

    register_analysis = _closed_mapping(
        result.get("registerAnalysis"), "registerAnalysis", "registerAnalysis"
    )
    register_model = _closed_mapping(
        register_analysis.get("model"), "registerAnalysis.model", "registerModel"
    )
    if dict(register_model) != REGISTER_MODEL:
        _fail("registerAnalysis.model does not match the closed AArch64/Darwin model")

    register_views_raw = _array(register_analysis.get("views"), "registerAnalysis.views")
    register_views = _index(
        register_views_raw,
        label="register view",
        pattern=_ID_PATTERNS["registerView"],
        shape="registerView",
    )
    register_view_by_storage: dict[str, Mapping[str, Any]] = {}
    for view in register_views.values():
        storage_id = view.get("storageValueId")
        if storage_id not in values or storage_id in register_view_by_storage:
            _fail("register views must map one-to-one to known raw storage values")
        if values[storage_id].get("registerName") != view.get("viewName"):
            _fail("register view name does not match raw SLEIGH register metadata")
        if view.get("canonicalBitWidth") != 64 or view.get("bitOffset") != 0:
            _fail("register view has an unsupported canonical width or bit offset")
        if view.get("bitWidth") not in {32, 64}:
            _fail("register view has an unsupported width")
        expected_read = "identity" if view.get("bitWidth") == 64 else "lowBits"
        expected_write = "replace" if view.get("bitWidth") == 64 else "zeroExtend"
        if view.get("readTransform") != expected_read or view.get("writeTransform") != expected_write:
            _fail("register view transforms do not match its width")
        register_view_by_storage[storage_id] = view

    register_versions_raw = _array(register_analysis.get("versions"), "registerAnalysis.versions")
    register_versions = _index(
        register_versions_raw,
        label="register version",
        pattern=_ID_PATTERNS["registerVersion"],
        shape="registerVersion",
    )
    for version in register_versions.values():
        if version.get("bitWidth") != 64:
            _fail("register version has an unsupported width")
        canonical = version.get("canonicalRegister")
        if canonical not in {*(f"x{index}" for index in range(31)), "sp"}:
            _fail("register version has an unsupported canonical register")
        kind = version.get("kind")
        operation_id = version.get("definingPcodeOpId")
        phi_id = version.get("definingRegisterPhiId")
        view_id = version.get("writeViewId")
        transform = version.get("writeTransform")
        source = version.get("sourceRange")
        if kind == "functionEntry":
            if any(item is not None for item in (operation_id, phi_id, view_id, transform, source)):
                _fail("function-entry register version has definition metadata")
        elif kind == "phi":
            if operation_id is not None or not isinstance(phi_id, str) or view_id is not None or transform is not None or source is not None:
                _fail("register phi version metadata is inconsistent")
        elif kind == "pcodeWrite":
            if operation_id not in operations or phi_id is not None or view_id not in register_views or transform not in {"replace", "zeroExtend"}:
                _fail("p-code register-write version metadata is inconsistent")
            if register_views[view_id].get("canonicalRegister") != canonical:
                _fail("p-code register-write version canonical family is inconsistent")
            _source_range(
                source,
                image_id=image_id,
                function_start=function_start,
                function_end=function_end,
                label="registerVersion.sourceRange",
            )
        elif kind == "callClobber":
            if operation_id not in operations or operations[operation_id].get("opcode") not in {"CALL", "CALLIND"} or phi_id is not None or view_id is not None or transform != "unknown":
                _fail("call-clobber register version metadata is inconsistent")
            if canonical not in DARWIN_CALL_GPR_CLOBBERS:
                _fail("call-clobber register version is outside the base ABI model")
            _source_range(
                source,
                image_id=image_id,
                function_start=function_start,
                function_end=function_end,
                label="registerVersion.sourceRange",
            )
        else:
            _fail("register version kind is invalid")

    register_bindings_raw = _array(register_analysis.get("bindings"), "registerAnalysis.bindings")
    register_bindings = _index(
        register_bindings_raw,
        label="register binding",
        pattern=_ID_PATTERNS["registerBinding"],
        shape="registerBinding",
    )
    binding_by_operation: dict[str, Mapping[str, Any]] = {}
    for binding in register_bindings.values():
        operation_id = binding.get("pcodeOpId")
        if operation_id not in operations or operation_id in binding_by_operation:
            _fail("register bindings must map one-to-one to p-code operations")
        operation = operations[operation_id]
        seen_operands: set[int] = set()
        for raw_read in _array(binding.get("reads"), "registerBinding.reads"):
            read = _closed_mapping(raw_read, "register read", "registerRead")
            operand_index = read.get("operandIndex")
            if type(operand_index) is not int or operand_index < 0 or operand_index >= len(operation["inputs"]) or operand_index in seen_operands:
                _fail("register read has an invalid or duplicate operand index")
            seen_operands.add(operand_index)
            storage_id = read.get("storageValueId")
            view_id = read.get("registerViewId")
            if operation["inputs"][operand_index] != storage_id or storage_id not in register_view_by_storage:
                _fail("register read does not match its p-code operand")
            view = register_view_by_storage[storage_id]
            if view.get("id") != view_id or read.get("canonicalRegister") != view.get("canonicalRegister") or read.get("readTransform") != view.get("readTransform"):
                _fail("register read does not match its canonical view")
            input_version_id = read.get("inputRegisterVersionId")
            if input_version_id not in register_versions:
                _fail("register read references an unknown version")
            if register_versions[input_version_id].get("canonicalRegister") != read.get("canonicalRegister"):
                _fail("register read version belongs to a different canonical register")
        raw_write = binding.get("write")
        if raw_write is not None:
            write = _closed_mapping(raw_write, "register write", "registerWrite")
            storage_id = write.get("storageValueId")
            if operation.get("output") != storage_id or storage_id not in register_view_by_storage:
                _fail("register write does not match its p-code output")
            view = register_view_by_storage[storage_id]
            if write.get("registerViewId") != view.get("id") or write.get("canonicalRegister") != view.get("canonicalRegister") or write.get("writeTransform") != view.get("writeTransform"):
                _fail("register write does not match its canonical view")
            output_id = write.get("outputRegisterVersionId")
            if output_id not in register_versions or register_versions[output_id].get("kind") != "pcodeWrite" or register_versions[output_id].get("definingPcodeOpId") != operation_id:
                _fail("register write output definition is inconsistent")
            if register_versions[output_id].get("canonicalRegister") != write.get("canonicalRegister"):
                _fail("register write output belongs to a different canonical register")
        clobber_ids = _array(
            binding.get("callClobberRegisterVersionIds"),
            "registerBinding.callClobberRegisterVersionIds",
        )
        if len(clobber_ids) != len(set(clobber_ids)):
            _fail("register binding call-clobber versions must be unique")
        for version_id in clobber_ids:
            if version_id not in register_versions or register_versions[version_id].get("kind") != "callClobber" or register_versions[version_id].get("definingPcodeOpId") != operation_id:
                _fail("register binding references an inconsistent call-clobber version")
        if operation.get("opcode") in {"CALL", "CALLIND"}:
            if len(clobber_ids) != len(DARWIN_CALL_GPR_CLOBBERS):
                _fail("Darwin call binding must define every modeled GPR clobber")
            clobber_registers = [
                register_versions[version_id].get("canonicalRegister")
                for version_id in clobber_ids
            ]
            if clobber_registers != list(DARWIN_CALL_GPR_CLOBBERS):
                _fail("Darwin call binding GPR clobbers are incomplete or misordered")
        elif clobber_ids:
            _fail("non-call register binding must not contain call clobbers")
        binding_by_operation[operation_id] = binding
    if set(binding_by_operation) != set(operations):
        _fail("register bindings must cover every p-code operation exactly once")

    register_phis_raw = _array(register_analysis.get("phis"), "registerAnalysis.phis")
    register_phis = _index(
        register_phis_raw,
        label="register phi",
        pattern=_ID_PATTERNS["registerPhi"],
        shape="registerPhi",
    )
    for phi_id, phi in register_phis.items():
        block_id = phi.get("blockId")
        output_id = phi.get("outputRegisterVersionId")
        if block_id not in blocks or output_id not in register_versions:
            _fail("register phi references an unknown block or output version")
        output_version = register_versions[output_id]
        if output_version.get("kind") != "phi" or output_version.get("definingRegisterPhiId") != phi_id or output_version.get("canonicalRegister") != phi.get("canonicalRegister"):
            _fail("register phi output definition is inconsistent")
        expected_paths = _expected_paths(blocks[block_id], function_start=function_start, edges=edges)
        incoming = _array(phi.get("incoming"), "registerPhi.incoming")
        incoming_ids: list[str] = []
        for raw_incoming, expected_path in _zip_equal_length(
            incoming,
            expected_paths,
            mismatch_message="register phi incoming count does not match predecessor paths",
        ):
            actual = _closed_mapping(raw_incoming, "register phi incoming", "registerPhiIncoming")
            if {key: actual.get(key) for key in expected_path} != expected_path:
                _fail("register phi incoming predecessor identity is inconsistent")
            version_id = actual.get("registerVersionId")
            if version_id not in register_versions:
                _fail("register phi incoming references an unknown version")
            incoming_ids.append(version_id)
        if phi.get("isTrivial") is not (bool(incoming_ids) and len(set(incoming_ids)) == 1):
            _fail("register phi isTrivial flag is inconsistent")

    call_effects_raw = _array(register_analysis.get("callEffects"), "registerAnalysis.callEffects")
    call_effects = _index(
        call_effects_raw,
        label="call register effect",
        pattern=_ID_PATTERNS["callRegisterEffect"],
        shape="callRegisterEffect",
    )
    effect_by_operation: dict[str, Mapping[str, Any]] = {}
    call_input_slice_count = 0
    call_clobber_slice_count = 0
    for effect in call_effects.values():
        operation_id = effect.get("pcodeOpId")
        if operation_id not in operations or operations[operation_id].get("opcode") not in {"CALL", "CALLIND"} or operation_id in effect_by_operation:
            _fail("call register effects must map one-to-one to call operations")
        expected_kind = "direct" if operations[operation_id].get("directTargetAddress") is not None else "indirect"
        if (
            effect.get("callKind") != expected_kind
            or effect.get("callingConvention") != "darwin-arm64-aapcs64"
            or effect.get("coverage") != "base-gpr-simd-nzcv"
        ):
            _fail("call register effect identity is inconsistent")

        inputs = _array(effect.get("inputs"), "callRegisterEffect.inputs")
        expected_input_count = len(DARWIN_CALL_GPR_INPUTS) + len(DARWIN_CALL_SIMD_INPUTS)
        if len(inputs) != expected_input_count:
            _fail("Darwin call register effect has incomplete conservative input slices")
        expected_input_names = [*DARWIN_CALL_GPR_INPUTS, *DARWIN_CALL_SIMD_INPUTS]
        for index, raw_input in enumerate(inputs):
            call_input = _closed_mapping(
                raw_input, "call register input", "callRegisterInput"
            )
            register_name = call_input.get("registerName")
            if register_name != expected_input_names[index]:
                _fail("Darwin call register input slices are incomplete or misordered")
            if call_input.get("bitOffset") != 0 or call_input.get("access") != "conservativeMayRead":
                _fail("call register input slice geometry or access is invalid")
            input_version_id = call_input.get("inputRegisterVersionId")
            if register_name in DARWIN_CALL_GPR_INPUTS:
                if call_input.get("registerClass") != "generalPurpose" or call_input.get("bitWidth") != 64:
                    _fail("GPR call input slice geometry is invalid")
                expected_reason = (
                    "possibleParameter"
                    if register_name.startswith("x") and register_name not in {"x8", "x30"}
                    else "possibleIndirectResultLocation"
                    if register_name == "x8"
                    else "linkRegister"
                    if register_name == "x30"
                    else "stackPointer"
                )
                if call_input.get("reason") != expected_reason:
                    _fail("GPR call input reason is inconsistent")
                if input_version_id not in register_versions:
                    _fail("GPR call input lacks a reaching register version")
                if register_versions[input_version_id].get("canonicalRegister") != register_name:
                    _fail("GPR call input version belongs to a different canonical register")
            else:
                if (
                    call_input.get("registerClass") != "simdFloatingPoint"
                    or call_input.get("bitWidth") != 128
                    or call_input.get("reason") != "possibleParameter"
                    or input_version_id is not None
                ):
                    _fail("SIMD call input slice is inconsistent with partial SSA coverage")
        call_input_slice_count += len(inputs)

        clobbers = _array(effect.get("clobbers"), "callRegisterEffect.clobbers")
        expected_clobber_count = len(DARWIN_CALL_GPR_CLOBBERS) + 32 + 4
        if len(clobbers) != expected_clobber_count:
            _fail("Darwin call register effect has incomplete clobber slices")
        expected_clobber_names = [
            *DARWIN_CALL_GPR_CLOBBERS,
            *(f"v{index}" for index in range(32)),
            "N",
            "Z",
            "C",
            "V",
        ]
        for index, raw_clobber in enumerate(clobbers):
            clobber = _closed_mapping(
                raw_clobber, "call register clobber", "callRegisterClobber"
            )
            register_name = clobber.get("registerName")
            if register_name != expected_clobber_names[index]:
                _fail("Darwin call register clobber slices are incomplete or misordered")
            output_id = clobber.get("outputRegisterVersionId")
            if register_name in DARWIN_CALL_GPR_CLOBBERS:
                expected_reason = (
                    "platformReserved"
                    if register_name == "x18"
                    else "linkRegisterCallerSaved"
                    if register_name == "x30"
                    else "callerSaved"
                )
                if (
                    clobber.get("registerClass") != "generalPurpose"
                    or clobber.get("bitOffset") != 0
                    or clobber.get("bitWidth") != 64
                    or clobber.get("reason") != expected_reason
                ):
                    _fail("GPR call clobber slice is inconsistent")
                if (
                    output_id not in register_versions
                    or register_versions[output_id].get("kind") != "callClobber"
                    or register_versions[output_id].get("definingPcodeOpId") != operation_id
                    or register_versions[output_id].get("canonicalRegister") != register_name
                ):
                    _fail("GPR call clobber lacks its semantic output version")
            elif isinstance(register_name, str) and register_name.startswith("v"):
                simd_index = int(register_name[1:])
                expected_geometry = (
                    (64, 64, "upperHalfCallerSaved")
                    if 8 <= simd_index <= 15
                    else (0, 128, "callerSaved")
                )
                if (
                    clobber.get("registerClass") != "simdFloatingPoint"
                    or (
                        clobber.get("bitOffset"),
                        clobber.get("bitWidth"),
                        clobber.get("reason"),
                    )
                    != expected_geometry
                    or output_id is not None
                ):
                    _fail("SIMD call clobber slice is inconsistent")
            else:
                if (
                    clobber.get("registerClass") != "conditionFlag"
                    or clobber.get("bitOffset") != 0
                    or clobber.get("bitWidth") != 1
                    or clobber.get("reason") != "undefinedAcrossCall"
                    or output_id is not None
                ):
                    _fail("condition-flag call clobber slice is inconsistent")
        call_clobber_slice_count += len(clobbers)
        _source_range(
            effect.get("sourceRange"),
            image_id=image_id,
            function_start=function_start,
            function_end=function_end,
            label="callRegisterEffect.sourceRange",
        )
        effect_by_operation[operation_id] = effect

    expected_call_operations = {
        operation_id
        for operation_id, operation in operations.items()
        if operation.get("opcode") in {"CALL", "CALLIND"}
    }
    if set(effect_by_operation) != expected_call_operations:
        _fail("call register effects must cover every call operation exactly once")

    try:
        expected_register_analysis = derive_register_analysis(
            values=values_raw,
            pcode_ops=operations_raw,
            basic_blocks=blocks_raw,
            edges=edges_raw,
            function_entry=function_start,
        )
    except RegisterDataflowDerivationError as error:
        _fail(f"raw result graph cannot be register-analyzed: {error}")
    if dict(register_analysis) != expected_register_analysis:
        _fail("registerAnalysis does not match deterministic AArch64/Darwin derivation")

    for name in ("recoveredVariables", "recoveredTypes", "structuredRegions", "pseudocodeTokens"):
        if result.get(name) != []:
            _fail(f"{name} must remain empty at this proof level")

    warnings = _array(result.get("warnings"), "warnings")
    warning_codes: set[str] = set()
    for raw_warning in warnings:
        warning = _closed_mapping(raw_warning, "warning", "warning")
        code = warning.get("code")
        message = warning.get("message")
        if (
            not isinstance(code, str)
            or _IDENTIFIER.fullmatch(code) is None
            or code in warning_codes
            or not isinstance(message, str)
            or not 1 <= len(message) <= 4096
        ):
            _fail("warning is invalid or duplicated")
        warning_codes.add(code)
    expected_warning_records = expected_warnings(
        unmapped_address_metadata_count=int(
            load_image_validation["unmappedAddressMetadataCount"]
        ),
        authenticated_pointer_patch_count=int(
            load_image_validation["authenticatedPointerPatchCount"]
        ),
    )
    if warnings != expected_warning_records:
        _fail("warnings do not match the deterministic capability/evidence contract")

    usage = _closed_mapping(result.get("resourceUsage"), "resourceUsage", "resourceUsage")
    expected_counts = {
        "mappedByteCount": mapped_byte_count,
        "effectiveMappedByteCount": load_image_validation["effectiveMappedByteCount"],
        "functionByteCount": function_byte_count,
        "effectiveFunctionByteCount": len(effective_function_bytes),
        "appliedPatchCount": load_image_validation["appliedPatchCount"],
        "unmappedAddressMetadataCount": load_image_validation[
            "unmappedAddressMetadataCount"
        ],
        "instructionCount": len(instructions),
        "valueCount": len(values),
        "pcodeOpCount": len(operations),
        "basicBlockCount": len(blocks),
        "edgeCount": len(edges),
        "callCount": len(calls),
        "ssaValueCount": len(ssa_values),
        "ssaBindingCount": len(bindings),
        "phiCount": len(phis),
        "heritageUseCount": len(heritage),
        "memoryVersionCount": len(memory_versions),
        "memoryPhiCount": len(memory_phis),
        "memoryEffectCount": len(memory_effects),
        "registerViewCount": len(register_views),
        "registerVersionCount": len(register_versions),
        "registerBindingCount": len(register_bindings),
        "registerPhiCount": len(register_phis),
        "callRegisterEffectCount": len(call_effects),
        "callRegisterInputSliceCount": call_input_slice_count,
        "callRegisterClobberSliceCount": call_clobber_slice_count,
    }
    for field, expected in expected_counts.items():
        if type(usage.get(field)) is not int or usage.get(field) != expected:
            _fail(f"resourceUsage.{field} does not match the result")

    content_hash = result.get("contentHash")
    if not isinstance(content_hash, str) or _SHA256.fullmatch(content_hash) is None:
        _fail("result contentHash is invalid")
    unhashed = copy.deepcopy(dict(result))
    del unhashed["contentHash"]
    if canonical_sha256(unhashed) != content_hash:
        _fail("result contentHash does not cover the complete result")
