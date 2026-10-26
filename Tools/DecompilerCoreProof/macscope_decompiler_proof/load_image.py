"""Deterministic effective-memory construction for the DCP-03 proof backend.

The request's memory regions remain the sole byte and address authority. This
module never opens or parses a Mach-O file. It applies a deliberately bounded,
closed subset of caller-supplied AArch64 Mach-O relocation and dyld chained
fixup records to an immutable analysis view. Raw bytes remain available for
provenance; effective bytes are consumed by instruction decoding and future
native-decompiler ``LoadImage`` adapters.

Records whose address is outside every supplied region are preserved as
unmapped evidence. Any record that points into supplied memory must be fully
understood and valid or derivation fails closed.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any

from .canonical import UINT64_MAX, bytes_sha256, format_address
from .request import AnalysisRequest, Fixup, MemoryRegion, Relocation


class EffectiveLoadImageError(ValueError):
    """Caller-provided address metadata cannot form a sound effective image."""


SUPPORTED_RELOCATION_KINDS: tuple[str, ...] = (
    "ARM64_RELOC_UNSIGNED",
    "ARM64_RELOC_BRANCH26",
    "ARM64_RELOC_PAGE21",
    "ARM64_RELOC_GOT_LOAD_PAGE21",
    "ARM64_RELOC_TLVP_LOAD_PAGE21",
    "ARM64_RELOC_PAGEOFF12",
    "ARM64_RELOC_GOT_LOAD_PAGEOFF12",
    "ARM64_RELOC_TLVP_LOAD_PAGEOFF12",
)
SUPPORTED_FIXUP_KINDS: tuple[str, ...] = (
    "DYLD_CHAINED_REBASE64",
    "DYLD_CHAINED_BIND64",
    "DYLD_CHAINED_AUTH_REBASE64",
    "DYLD_CHAINED_AUTH_BIND64",
)
_AUTH_FIXUP_KINDS = frozenset(
    {"DYLD_CHAINED_AUTH_REBASE64", "DYLD_CHAINED_AUTH_BIND64"}
)
_PAGE21_KINDS = frozenset(
    {
        "ARM64_RELOC_PAGE21",
        "ARM64_RELOC_GOT_LOAD_PAGE21",
        "ARM64_RELOC_TLVP_LOAD_PAGE21",
    }
)
_PAGEOFF12_KINDS = frozenset(
    {
        "ARM64_RELOC_PAGEOFF12",
        "ARM64_RELOC_GOT_LOAD_PAGEOFF12",
        "ARM64_RELOC_TLVP_LOAD_PAGEOFF12",
    }
)
_AUTH_KEYS = frozenset({"ia", "ib", "da", "db"})

LOAD_IMAGE_MODEL: dict[str, object] = {
    "architecture": "AArch64",
    "byteOrder": "little",
    "pointerWidthBits": 64,
    "relocationModel": "mach-o-arm64-relocation-subset-v1",
    "fixupModel": "dyld-chained-pointer-normalization-v1",
    "patchPolicy": "fail-closed-mapped-preserve-unmapped",
    "authenticatedPointerTreatment": (
        "materialize-unsigned-target-with-authentication-evidence"
    ),
    "supportedRelocationKinds": list(SUPPORTED_RELOCATION_KINDS),
    "supportedFixupKinds": list(SUPPORTED_FIXUP_KINDS),
}


@dataclass(frozen=True)
class _PatchDraft:
    source_kind: str
    source_index: int
    address: int
    width: int
    kind: str
    encoding: str
    target_address: int
    symbol: str | None
    addend: int | None
    authenticated: bool | None
    key: str | None
    diversity: int | None
    replacement: bytes


@dataclass(frozen=True)
class EffectiveLoadImage:
    """Immutable raw/effective byte views and their closed provenance DTO."""

    request: AnalysisRequest
    effective_regions: tuple[bytes, ...]
    output: dict[str, object]

    def read(self, start: int, end: int, *, require_executable: bool = False) -> bytes:
        if start < 0 or end < start or end > UINT64_MAX + 1:
            raise EffectiveLoadImageError("requested effective-memory range is malformed")
        cursor = start
        result = bytearray()
        for index, region in enumerate(self.request.memory_regions):
            if region.end <= cursor:
                continue
            if region.start > cursor:
                break
            if require_executable and region.permissions[2] != "x":
                raise EffectiveLoadImageError(
                    "effective function range includes non-executable memory"
                )
            take_end = min(end, region.end)
            offset = cursor - region.start
            result.extend(
                self.effective_regions[index][offset : offset + (take_end - cursor)]
            )
            cursor = take_end
            if cursor == end:
                return bytes(result)
        raise EffectiveLoadImageError(
            "effective memory range is not fully mapped: "
            f"{format_address(start)}..{format_address(end)}"
        )

    def patch_ids_intersecting(self, start: int, end: int) -> list[str]:
        identifiers: list[str] = []
        patches = self.output["patches"]
        assert isinstance(patches, list)
        for raw in patches:
            assert isinstance(raw, dict)
            address = int(str(raw["address"]), 16)
            width = int(raw["width"])
            if address < end and start < address + width:
                identifiers.append(str(raw["id"]))
        return identifiers


def _region_index(regions: tuple[MemoryRegion, ...], address: int) -> int | None:
    for index, region in enumerate(regions):
        if region.start <= address < region.end:
            return index
        if address < region.start:
            return None
    return None


def _source_range(request: AnalysisRequest, address: int, width: int) -> dict[str, str]:
    return {
        "imageId": request.image_id,
        "startAddress": format_address(address),
        "endAddressExclusive": format_address(address + width),
    }


def _checked_target(base: int, addend: int, *, label: str) -> int:
    value = base + addend
    if not 0 <= value <= UINT64_MAX:
        raise EffectiveLoadImageError(
            f"{label} target plus addend exceeds unsigned 64-bit range"
        )
    return value


def _resolve_relocation_target(request: AnalysisRequest, relocation: Relocation) -> int:
    resolved_symbol: int | None = None
    if relocation.symbol is not None:
        addresses = sorted(
            {symbol.address for symbol in request.symbols if symbol.name == relocation.symbol}
        )
        if not addresses:
            raise EffectiveLoadImageError(
                "relocation symbol has no exact caller-supplied match: "
                f"{relocation.symbol}"
            )
        if len(addresses) != 1:
            raise EffectiveLoadImageError(
                "relocation symbol resolves to multiple addresses: "
                f"{relocation.symbol}"
            )
        resolved_symbol = addresses[0]
    if relocation.target_address is None and resolved_symbol is None:
        raise EffectiveLoadImageError(
            "mapped relocation has neither targetAddress nor symbol"
        )
    if (
        relocation.target_address is not None
        and resolved_symbol is not None
        and relocation.target_address != resolved_symbol
    ):
        raise EffectiveLoadImageError(
            "relocation targetAddress contradicts its symbol evidence"
        )
    base = relocation.target_address if relocation.target_address is not None else resolved_symbol
    assert base is not None
    return _checked_target(base, relocation.addend, label="relocation")


def _u32(data: bytes) -> int:
    if len(data) != 4:
        raise EffectiveLoadImageError(
            "AArch64 instruction patch requires exactly four bytes"
        )
    return int.from_bytes(data, "little")


def _branch26(word: int, *, address: int, target: int) -> bytes:
    if word & 0x7C000000 != 0x14000000:
        raise EffectiveLoadImageError(
            "ARM64_RELOC_BRANCH26 does not reference a B or BL instruction"
        )
    displacement = target - address
    if displacement % 4 != 0:
        raise EffectiveLoadImageError(
            "ARM64_RELOC_BRANCH26 target is not four-byte aligned"
        )
    immediate = displacement // 4
    if not -(1 << 25) <= immediate <= (1 << 25) - 1:
        raise EffectiveLoadImageError(
            "ARM64_RELOC_BRANCH26 target is out of signed 26-bit range"
        )
    patched = (word & 0xFC000000) | (immediate & 0x03FFFFFF)
    return patched.to_bytes(4, "little")


def _page21(word: int, *, address: int, target: int) -> bytes:
    if word & 0x9F000000 != 0x90000000:
        raise EffectiveLoadImageError(
            "ARM64_RELOC_PAGE21 does not reference an ADRP instruction"
        )
    page_delta = (target >> 12) - (address >> 12)
    if not -(1 << 20) <= page_delta <= (1 << 20) - 1:
        raise EffectiveLoadImageError(
            "ARM64_RELOC_PAGE21 target page is out of signed 21-bit range"
        )
    immediate = page_delta & ((1 << 21) - 1)
    immediate_low = immediate & 0x3
    immediate_high = (immediate >> 2) & 0x7FFFF
    patched = word & ~(0x60000000 | 0x00FFFFE0)
    patched |= immediate_low << 29
    patched |= immediate_high << 5
    return patched.to_bytes(4, "little")


def _pageoff12(word: int, *, kind: str, target: int) -> tuple[bytes, str]:
    page_offset = target & 0xFFF

    # ADD (immediate), 32- or 64-bit, without flags. PAGEOFF12 relocation
    # semantics do not apply to SUB/ADDS/SUBS or shifted-by-12 forms.
    if word & 0x7F000000 == 0x11000000:
        if kind != "ARM64_RELOC_PAGEOFF12":
            raise EffectiveLoadImageError(
                "GOT/TLVP PAGEOFF12 relocation requires a load/store instruction"
            )
        if word & (1 << 22):
            raise EffectiveLoadImageError(
                "ARM64_RELOC_PAGEOFF12 ADD instruction uses unsupported "
                "shift-by-12 encoding"
            )
        patched = (word & ~(0xFFF << 10)) | (page_offset << 10)
        return patched.to_bytes(4, "little"), "aarch64AddImmediatePageOffset12"

    # Integer scalar load/store unsigned immediate. SIMD/FP forms have V=1
    # (bit 26) and are intentionally outside this bounded proof contract.
    if word & 0x3B000000 == 0x39000000 and word & (1 << 26) == 0:
        scale = (word >> 30) & 0x3
        opc = (word >> 22) & 0x3

        # Keep this proof limited to architecturally defined scalar integer
        # loads and stores.  The same broad encoding class also contains PRFM
        # (size=3, opc=2) and reserved combinations; accepting either would
        # overstate the frozen PAGEOFF12 contract.
        if (scale == 3 and opc == 2) or (scale >= 2 and opc == 3):
            raise EffectiveLoadImageError(
                "ARM64_RELOC_PAGEOFF12 references prefetch or reserved "
                "load/store encoding"
            )
        alignment = 1 << scale
        if page_offset % alignment != 0:
            raise EffectiveLoadImageError(
                "ARM64_RELOC_PAGEOFF12 target offset violates load/store "
                "access alignment"
            )
        immediate = page_offset // alignment
        if immediate > 0xFFF:
            raise EffectiveLoadImageError(
                "ARM64_RELOC_PAGEOFF12 scaled load/store offset exceeds 12 bits"
            )
        patched = (word & ~(0xFFF << 10)) | (immediate << 10)
        return (
            patched.to_bytes(4, "little"),
            "aarch64UnsignedLoadStorePageOffset12",
        )

    raise EffectiveLoadImageError(
        "ARM64_RELOC_PAGEOFF12 references an unsupported instruction encoding"
    )


def encode_relocation_replacement(
    *,
    kind: str,
    address: int,
    target_address: int,
    original: bytes,
) -> tuple[bytes, str]:
    """Encode one already-resolved relocation without consulting image state.

    Keeping this operation explicit lets the structured-result verifier check
    that a serialized patch's effective bytes actually encode its claimed
    target even when the original request is not attached.  Target and symbol
    evidence are validated separately.
    """

    if kind == "ARM64_RELOC_UNSIGNED":
        if len(original) != 8:
            raise EffectiveLoadImageError(
                "ARM64_RELOC_UNSIGNED requires exactly eight original bytes"
            )
        return target_address.to_bytes(8, "little"), "littleEndianUnsigned64"
    if kind == "ARM64_RELOC_BRANCH26":
        if address % 4 != 0:
            raise EffectiveLoadImageError(
                "ARM64_RELOC_BRANCH26 address is not four-byte aligned"
            )
        return (
            _branch26(_u32(original), address=address, target=target_address),
            "aarch64Branch26",
        )
    if kind in _PAGE21_KINDS:
        if address % 4 != 0:
            raise EffectiveLoadImageError(
                "ARM64_RELOC_PAGE21 address is not four-byte aligned"
            )
        return (
            _page21(_u32(original), address=address, target=target_address),
            "aarch64AdrpPage21",
        )
    if kind in _PAGEOFF12_KINDS:
        if address % 4 != 0:
            raise EffectiveLoadImageError(
                "ARM64_RELOC_PAGEOFF12 address is not four-byte aligned"
            )
        return _pageoff12(_u32(original), kind=kind, target=target_address)
    raise EffectiveLoadImageError(f"unsupported mapped relocation kind: {kind}")


def _relocation_patch(
    request: AnalysisRequest,
    relocation: Relocation,
    *,
    source_index: int,
    original: bytes,
) -> _PatchDraft:
    target = _resolve_relocation_target(request, relocation)
    replacement, encoding = encode_relocation_replacement(
        kind=relocation.kind,
        address=relocation.address,
        target_address=target,
        original=original,
    )
    return _PatchDraft(
        source_kind="relocation",
        source_index=source_index,
        address=relocation.address,
        width=len(replacement),
        kind=relocation.kind,
        encoding=encoding,
        target_address=target,
        symbol=relocation.symbol,
        addend=relocation.addend,
        authenticated=None,
        key=None,
        diversity=None,
        replacement=replacement,
    )


def _fixup_patch(fixup: Fixup, *, source_index: int) -> _PatchDraft:
    if fixup.kind not in SUPPORTED_FIXUP_KINDS:
        raise EffectiveLoadImageError(
            f"unsupported mapped fixup kind: {fixup.kind}"
        )
    if fixup.target_address is None:
        raise EffectiveLoadImageError("mapped dyld chained fixup lacks targetAddress")
    kind_is_authenticated = fixup.kind in _AUTH_FIXUP_KINDS
    if fixup.authenticated != kind_is_authenticated:
        raise EffectiveLoadImageError(
            "dyld chained fixup kind contradicts authenticated flag"
        )
    if kind_is_authenticated:
        if fixup.key not in _AUTH_KEYS or fixup.diversity is None:
            raise EffectiveLoadImageError(
                "authenticated dyld chained fixup requires ia/ib/da/db key "
                "and diversity"
            )
    elif fixup.key is not None or fixup.diversity is not None:
        raise EffectiveLoadImageError(
            "unauthenticated dyld chained fixup contains authentication metadata"
        )
    return _PatchDraft(
        source_kind="fixup",
        source_index=source_index,
        address=fixup.address,
        width=8,
        kind=fixup.kind,
        encoding="normalizedPointer64",
        target_address=fixup.target_address,
        symbol=None,
        addend=None,
        authenticated=fixup.authenticated,
        key=fixup.key,
        diversity=fixup.diversity,
        replacement=fixup.target_address.to_bytes(8, "little"),
    )


def _width_for_relocation(kind: str) -> int:
    if kind == "ARM64_RELOC_UNSIGNED":
        return 8
    if kind in SUPPORTED_RELOCATION_KINDS:
        return 4
    raise EffectiveLoadImageError(f"unsupported mapped relocation kind: {kind}")


def _intersecting_region_indices(
    regions: tuple[MemoryRegion, ...],
    address: int,
    width: int,
) -> list[int]:
    patch_end = address + width
    return [
        index
        for index, region in enumerate(regions)
        if address < region.end and region.start < patch_end
    ]


def _classify_patch_location(
    regions: tuple[MemoryRegion, ...],
    *,
    address: int,
    width: int,
) -> int | None:
    if width <= 0 or address > UINT64_MAX - width:
        raise EffectiveLoadImageError(
            "address metadata patch range exceeds unsigned 64-bit address space"
        )
    intersections = _intersecting_region_indices(regions, address, width)
    if not intersections:
        return None
    if len(intersections) != 1:
        raise EffectiveLoadImageError(
            "mapped address metadata patch crosses a memory-region boundary"
        )
    region_index = intersections[0]
    region = regions[region_index]
    if not (region.start <= address and address + width <= region.end):
        raise EffectiveLoadImageError(
            "mapped address metadata patch partially overlaps a memory region"
        )
    return region_index


def build_effective_load_image(request: AnalysisRequest) -> EffectiveLoadImage:
    """Derive the canonical analysis memory view from caller-owned evidence."""

    mutable_regions = [bytearray(region.data) for region in request.memory_regions]
    mapped_drafts: list[tuple[int, str, int, Relocation | Fixup]] = []
    unmapped: list[dict[str, object]] = []

    for index, relocation in enumerate(request.relocations):
        if relocation.kind in SUPPORTED_RELOCATION_KINDS:
            width = _width_for_relocation(relocation.kind)
            region_index = _classify_patch_location(
                request.memory_regions,
                address=relocation.address,
                width=width,
            )
        else:
            region_index = _region_index(request.memory_regions, relocation.address)
            if region_index is not None:
                raise EffectiveLoadImageError(
                    f"unsupported mapped relocation kind: {relocation.kind}"
                )
        if region_index is None:
            unmapped.append(
                {
                    "sourceKind": "relocation",
                    "sourceIndex": index,
                    "address": format_address(relocation.address),
                    "kind": relocation.kind,
                    "reason": "outsideSuppliedMemory",
                }
            )
        else:
            mapped_drafts.append(
                (relocation.address, "relocation", index, relocation)
            )

    for index, fixup in enumerate(request.fixups):
        if fixup.kind in SUPPORTED_FIXUP_KINDS:
            region_index = _classify_patch_location(
                request.memory_regions,
                address=fixup.address,
                width=8,
            )
        else:
            region_index = _region_index(request.memory_regions, fixup.address)
            if region_index is not None:
                raise EffectiveLoadImageError(
                    f"unsupported mapped fixup kind: {fixup.kind}"
                )
        if region_index is None:
            unmapped.append(
                {
                    "sourceKind": "fixup",
                    "sourceIndex": index,
                    "address": format_address(fixup.address),
                    "kind": fixup.kind,
                    "reason": "outsideSuppliedMemory",
                }
            )
        else:
            mapped_drafts.append((fixup.address, "fixup", index, fixup))

    mapped_drafts.sort(
        key=lambda item: (item[0], 0 if item[1] == "relocation" else 1, item[2])
    )
    unmapped.sort(
        key=lambda item: (
            int(str(item["address"]), 16),
            0 if item["sourceKind"] == "relocation" else 1,
            int(item["sourceIndex"]),
        )
    )

    patches: list[dict[str, object]] = []
    previous_end = -1
    applied_by_region: list[list[str]] = [[] for _ in request.memory_regions]
    for _, source_kind, source_index, source in mapped_drafts:
        address = source.address
        if source_kind == "relocation":
            assert isinstance(source, Relocation)
            width = _width_for_relocation(source.kind)
        else:
            assert isinstance(source, Fixup)
            if source.kind not in SUPPORTED_FIXUP_KINDS:
                raise EffectiveLoadImageError(
                    f"unsupported mapped fixup kind: {source.kind}"
                )
            width = 8

        region_index = _region_index(request.memory_regions, address)
        assert region_index is not None
        region = request.memory_regions[region_index]
        if address + width > region.end:
            raise EffectiveLoadImageError(
                "mapped address metadata patch crosses a memory-region boundary"
            )
        if address < previous_end:
            raise EffectiveLoadImageError(
                "mapped relocation and fixup patches overlap"
            )
        previous_end = address + width

        offset = address - region.start
        original = bytes(mutable_regions[region_index][offset : offset + width])
        if source_kind == "relocation":
            draft = _relocation_patch(
                request,
                source,
                source_index=source_index,
                original=original,
            )
        else:
            draft = _fixup_patch(source, source_index=source_index)
        if draft.width != width:
            raise EffectiveLoadImageError(
                "internal effective-image patch width mismatch"
            )

        mutable_regions[region_index][offset : offset + width] = draft.replacement
        identifier = f"patch{len(patches):06d}"
        applied_by_region[region_index].append(identifier)
        patches.append(
            {
                "id": identifier,
                "sourceKind": draft.source_kind,
                "sourceIndex": draft.source_index,
                "address": format_address(draft.address),
                "width": draft.width,
                "kind": draft.kind,
                "encoding": draft.encoding,
                "targetAddress": format_address(draft.target_address),
                "symbol": draft.symbol,
                "addend": draft.addend,
                "authenticated": draft.authenticated,
                "key": draft.key,
                "diversity": draft.diversity,
                "originalBytesHex": original.hex(),
                "effectiveBytesHex": draft.replacement.hex(),
                "sourceRange": _source_range(
                    request,
                    draft.address,
                    draft.width,
                ),
            }
        )

    effective_regions = tuple(bytes(region) for region in mutable_regions)
    region_output: list[dict[str, object]] = []
    for index, region in enumerate(request.memory_regions):
        region_output.append(
            {
                "name": region.name,
                "startAddress": format_address(region.start),
                "endAddressExclusive": format_address(region.end),
                "permissions": region.permissions,
                "byteCount": len(region.data),
                "rawSha256": bytes_sha256(region.data),
                "effectiveSha256": bytes_sha256(effective_regions[index]),
                "appliedPatchIds": applied_by_region[index],
            }
        )

    output: dict[str, object] = {
        "model": {
            key: list(value) if isinstance(value, list) else value
            for key, value in LOAD_IMAGE_MODEL.items()
        },
        "memoryRegions": region_output,
        "patches": patches,
        "unmappedEvidence": unmapped,
    }
    return EffectiveLoadImage(
        request=request,
        effective_regions=effective_regions,
        output=output,
    )
