"""Deterministic thin Mach-O carrier for DCP-03B2 effective memory.

The carrier is not a reconstructed application binary and never becomes an
image authority. It is a bounded transport container generated exclusively from
an already validated :class:`AnalysisRequest`. Raw request bytes remain the
provenance authority. DCP-03B2's fail-closed effective-load-image layer applies
the supported relocation/fixup subset, and only those derived effective bytes
are placed in the carrier consumed by libghidra.
"""

from __future__ import annotations

import hashlib
import os
import stat
import struct
from collections.abc import Iterator, Sequence
from dataclasses import dataclass
from pathlib import Path
from typing import TypeVar

from macscope_decompiler_proof.canonical import (
    bytes_sha256,
    canonical_json_bytes,
    canonical_sha256,
    format_address,
)
from macscope_decompiler_proof.load_image import (
    EffectiveLoadImage,
    EffectiveLoadImageError,
    build_effective_load_image,
)
from macscope_decompiler_proof.request import AnalysisRequest, MemoryRegion, Symbol

from .contract import MAX_CARRIER_BYTES, MAX_CARRIER_SECTIONS
from .errors import CarrierBuildError

MH_MAGIC_64 = 0xFEEDFACF
CPU_TYPE_ARM64 = 0x0100000C
CPU_SUBTYPE_ARM64_ALL = 0
MH_EXECUTE = 2
MH_NOUNDEFS = 0x1
MH_DYLDLINK = 0x4
MH_TWOLEVEL = 0x80
MH_PIE = 0x200000
LC_SEGMENT_64 = 0x19
LC_SYMTAB = 0x2
LC_UUID = 0x1B
VM_PROT_READ = 0x1
VM_PROT_WRITE = 0x2
VM_PROT_EXECUTE = 0x4
N_EXT = 0x01
N_ABS = 0x02
N_SECT = 0x0E
S_REGULAR = 0x0
S_ATTR_SOME_INSTRUCTIONS = 0x00000400
S_ATTR_PURE_INSTRUCTIONS = 0x80000000
PAGE_SIZE = 0x1000
HEADER_SIZE = 32
SEGMENT_COMMAND_SIZE = 72
SECTION_SIZE = 80
UUID_COMMAND_SIZE = 24
SYMTAB_COMMAND_SIZE = 24
NLIST64_SIZE = 16

_LeftValue = TypeVar("_LeftValue")
_RightValue = TypeVar("_RightValue")


@dataclass(frozen=True)
class CarrierArtifact:
    """Immutable carrier bytes, provenance manifest, and effective byte view."""

    data: bytes
    manifest: dict[str, object]
    load_image: EffectiveLoadImage

    @property
    def sha256(self) -> str:
        return bytes_sha256(self.data)

    def write(self, path: Path) -> None:
        """Write to a caller-created ordinary directory without following symlinks."""
        parent = path.parent
        try:
            parent_metadata = parent.lstat()
        except OSError as error:
            raise CarrierBuildError("carrier output directory is inaccessible") from error
        if not stat.S_ISDIR(parent_metadata.st_mode) or stat.S_ISLNK(parent_metadata.st_mode):
            raise CarrierBuildError("carrier output directory must be an ordinary directory")
        if path.exists() or path.is_symlink():
            raise CarrierBuildError("carrier output path must not already exist")
        flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0)
        try:
            descriptor = os.open(path, flags, 0o600)
            with os.fdopen(descriptor, "wb") as stream:
                stream.write(self.data)
                stream.flush()
                os.fsync(stream.fileno())
        except OSError as error:
            raise CarrierBuildError("carrier could not be written safely") from error


def _align(value: int, alignment: int) -> int:
    if alignment <= 0 or alignment & (alignment - 1):
        raise CarrierBuildError("internal carrier alignment is invalid")
    return (value + alignment - 1) & ~(alignment - 1)


def _zip_equal_length(
    left: Sequence[_LeftValue],
    right: Sequence[_RightValue],
    *,
    mismatch_message: str,
) -> Iterator[tuple[_LeftValue, _RightValue]]:
    """Pair two closed sequences without relying on Python 3.10's zip strict flag."""

    if len(left) != len(right):
        raise CarrierBuildError(mismatch_message)
    return zip(left, right)


def _name16(value: str) -> bytes:
    encoded = value.encode("ascii")
    if not encoded or len(encoded) > 16 or b"\x00" in encoded:
        raise CarrierBuildError("internal Mach-O name is invalid")
    return encoded.ljust(16, b"\x00")


def _segment_name(index: int, region: MemoryRegion) -> str:
    if index == 0 and region.permissions[2] == "x":
        return "__TEXT"
    if index == 0 and region.permissions[1] == "w":
        return "__DATA"
    prefix = (
        "__X"
        if region.permissions[2] == "x"
        else "__D"
        if region.permissions[1] == "w"
        else "__R"
    )
    return f"{prefix}{index:013x}"


def _section_name(index: int, region: MemoryRegion) -> str:
    if index == 0 and region.permissions[2] == "x":
        return "__text"
    if index == 0 and region.permissions[1] == "w":
        return "__data"
    prefix = (
        "__x"
        if region.permissions[2] == "x"
        else "__d"
        if region.permissions[1] == "w"
        else "__r"
    )
    return f"{prefix}{index:013x}"


def _vm_protection(permissions: str) -> int:
    value = 0
    if permissions[0] == "r":
        value |= VM_PROT_READ
    if permissions[1] == "w":
        value |= VM_PROT_WRITE
    if permissions[2] == "x":
        value |= VM_PROT_EXECUTE
    return value


def _section_flags(region: MemoryRegion) -> int:
    if region.permissions[2] == "x":
        return S_REGULAR | S_ATTR_SOME_INSTRUCTIONS | S_ATTR_PURE_INSTRUCTIONS
    return S_REGULAR


def _section_index(regions: tuple[MemoryRegion, ...], address: int) -> int:
    for index, region in enumerate(regions, start=1):
        if region.start <= address < region.end:
            return index
    return 0


def _carrier_symbols(request: AnalysisRequest) -> tuple[Symbol, ...]:
    values = list(request.symbols)
    if not any(
        symbol.address == request.function_entry
        and symbol.name == request.function_name
        for symbol in values
    ):
        values.append(
            Symbol(
                image_id=request.image_id,
                address=request.function_entry,
                name=request.function_name,
                kind="function",
            )
        )
    unique: dict[tuple[int, str, str], Symbol] = {}
    for symbol in values:
        unique[(symbol.address, symbol.kind, symbol.name)] = symbol
    return tuple(
        sorted(unique.values(), key=lambda item: (item.address, item.kind, item.name))
    )


def _symbol_bytes(
    request: AnalysisRequest,
    regions: tuple[MemoryRegion, ...],
) -> tuple[bytes, bytes, tuple[Symbol, ...]]:
    symbols = _carrier_symbols(request)
    strings = bytearray(b"\x00")
    nlists = bytearray()
    for symbol in symbols:
        encoded = symbol.name.encode("utf-8")
        if not encoded or b"\x00" in encoded:
            raise CarrierBuildError("symbol name cannot be represented in the carrier")
        string_offset = len(strings)
        if string_offset > 0xFFFFFFFF:
            raise CarrierBuildError("carrier string table exceeds Mach-O limits")
        strings.extend(encoded)
        strings.append(0)
        section = _section_index(regions, symbol.address)
        n_type = (N_SECT if section else N_ABS) | N_EXT
        nlists.extend(
            struct.pack("<IBBHQ", string_offset, n_type, section, 0, symbol.address)
        )
    return bytes(nlists), bytes(strings), symbols


def _effective_load_image(
    request: AnalysisRequest,
    supplied: EffectiveLoadImage | None,
) -> EffectiveLoadImage:
    try:
        value = supplied if supplied is not None else build_effective_load_image(request)
    except EffectiveLoadImageError as error:
        raise CarrierBuildError("effective load image could not be derived") from error
    if value.request.request_sha256 != request.request_sha256:
        raise CarrierBuildError("effective load image belongs to a different request")
    if len(value.effective_regions) != len(request.memory_regions):
        raise CarrierBuildError("effective load image region count is inconsistent")
    return value


def build_macho_carrier(
    request: AnalysisRequest,
    *,
    load_image: EffectiveLoadImage | None = None,
) -> CarrierArtifact:
    """Build a deterministic thin arm64 Mach-O from verified effective bytes."""

    regions = request.memory_regions
    if not regions or len(regions) > MAX_CARRIER_SECTIONS:
        raise CarrierBuildError(
            f"carrier requires 1...{MAX_CARRIER_SECTIONS} memory regions"
        )

    effective = _effective_load_image(request, load_image)

    # Re-read both authorities so this seam remains self-contained. The raw read
    # proves request coverage; the effective read proves that every instruction
    # byte consumed by libghidra exists in the derived executable view.
    request.read(
        request.function_entry,
        request.function_end,
        require_executable=True,
    )
    effective.read(
        request.function_entry,
        request.function_end,
        require_executable=True,
    )

    nlist_bytes, string_bytes, symbols = _symbol_bytes(request, regions)
    ncmds = len(regions) + 2
    sizeofcmds = (
        len(regions) * (SEGMENT_COMMAND_SIZE + SECTION_SIZE)
        + UUID_COMMAND_SIZE
        + SYMTAB_COMMAND_SIZE
    )
    payload_cursor = _align(HEADER_SIZE + sizeofcmds, PAGE_SIZE)

    load_image_regions = effective.output.get("memoryRegions")
    if not isinstance(load_image_regions, list) or len(load_image_regions) != len(regions):
        raise CarrierBuildError("effective load image output is malformed")

    mappings: list[dict[str, object]] = []
    segment_layout: list[tuple[int, MemoryRegion, bytes, str, str, int]] = []
    for index, (region, effective_bytes) in enumerate(
        _zip_equal_length(
            regions,
            effective.effective_regions,
            mismatch_message="effective load image region count is inconsistent",
        )
    ):
        if len(effective_bytes) != len(region.data):
            raise CarrierBuildError("effective memory region changed byte count")
        load_image_region = load_image_regions[index]
        if not isinstance(load_image_region, dict):
            raise CarrierBuildError("effective load image region record is malformed")
        patch_ids = load_image_region.get("appliedPatchIds")
        if not isinstance(patch_ids, list) or not all(
            isinstance(item, str) for item in patch_ids
        ):
            raise CarrierBuildError("effective load image patch ownership is malformed")

        file_offset = payload_cursor
        payload_cursor = _align(file_offset + len(effective_bytes), PAGE_SIZE)
        segment_name = _segment_name(index, region)
        section_name = _section_name(index, region)
        segment_layout.append(
            (index, region, effective_bytes, segment_name, section_name, file_offset)
        )
        mappings.append(
            {
                "id": f"map{index:06d}",
                "regionName": region.name,
                "segmentName": segment_name,
                "sectionName": section_name,
                "vmStartAddress": format_address(region.start),
                "vmEndAddressExclusive": format_address(region.end),
                "fileOffset": format_address(file_offset),
                "fileSize": len(effective_bytes),
                "permissions": region.permissions,
                "rawSha256": bytes_sha256(region.data),
                "effectiveSha256": bytes_sha256(effective_bytes),
                "appliedPatchIds": list(patch_ids),
            }
        )

    symbol_offset = _align(payload_cursor, 8)
    string_offset = symbol_offset + len(nlist_bytes)
    string_size = _align(len(string_bytes), 4)
    total_size = string_offset + string_size
    if total_size > MAX_CARRIER_BYTES:
        raise CarrierBuildError("carrier exceeds the fixed 300 MiB bound")
    if (
        symbol_offset > 0xFFFFFFFF
        or string_offset > 0xFFFFFFFF
        or string_size > 0xFFFFFFFF
    ):
        raise CarrierBuildError("carrier exceeds 32-bit Mach-O symbol-table offsets")

    function_file_offset: int | None = None
    for _index, region, _effective_bytes, _segment, _section, file_offset in segment_layout:
        if region.start <= request.function_entry < region.end:
            function_file_offset = file_offset + request.function_entry - region.start
            break
    if function_file_offset is None:
        raise CarrierBuildError("function entry is not mapped into the carrier")

    commands = bytearray()
    for _index, region, effective_bytes, segment_name, section_name, file_offset in segment_layout:
        protection = _vm_protection(region.permissions)
        commands.extend(
            struct.pack(
                "<II16sQQQQiiII",
                LC_SEGMENT_64,
                SEGMENT_COMMAND_SIZE + SECTION_SIZE,
                _name16(segment_name),
                region.start,
                len(effective_bytes),
                file_offset,
                len(effective_bytes),
                protection,
                protection,
                1,
                0,
            )
        )
        alignment_power = 2 if region.permissions[2] == "x" else 3
        commands.extend(
            struct.pack(
                "<16s16sQQIIIIIIII",
                _name16(section_name),
                _name16(segment_name),
                region.start,
                len(effective_bytes),
                file_offset,
                alignment_power,
                0,
                0,
                _section_flags(region),
                0,
                0,
                0,
            )
        )

    uuid_bytes = bytes.fromhex(request.image_uuid.replace("-", ""))
    if len(uuid_bytes) != 16:
        raise CarrierBuildError("image UUID cannot be represented as LC_UUID")
    commands.extend(struct.pack("<II16s", LC_UUID, UUID_COMMAND_SIZE, uuid_bytes))
    commands.extend(
        struct.pack(
            "<IIIIII",
            LC_SYMTAB,
            SYMTAB_COMMAND_SIZE,
            symbol_offset,
            len(symbols),
            string_offset,
            string_size,
        )
    )
    if len(commands) != sizeofcmds:
        raise CarrierBuildError("internal Mach-O load-command size mismatch")

    header = struct.pack(
        "<IiiIIIII",
        MH_MAGIC_64,
        CPU_TYPE_ARM64,
        CPU_SUBTYPE_ARM64_ALL,
        MH_EXECUTE,
        ncmds,
        sizeofcmds,
        MH_NOUNDEFS | MH_DYLDLINK | MH_TWOLEVEL | MH_PIE,
        0,
    )
    carrier = bytearray(total_size)
    carrier[:HEADER_SIZE] = header
    carrier[HEADER_SIZE : HEADER_SIZE + sizeofcmds] = commands
    for _index, region, effective_bytes, _segment, _section, file_offset in segment_layout:
        carrier[file_offset : file_offset + len(effective_bytes)] = effective_bytes
    carrier[symbol_offset : symbol_offset + len(nlist_bytes)] = nlist_bytes
    carrier[string_offset : string_offset + len(string_bytes)] = string_bytes

    raw_function = request.read(
        request.function_entry,
        request.function_end,
        require_executable=True,
    )
    effective_function = effective.read(
        request.function_entry,
        request.function_end,
        require_executable=True,
    )
    patches = effective.output.get("patches")
    unmapped = effective.output.get("unmappedEvidence")
    if not isinstance(patches, list) or not isinstance(unmapped, list):
        raise CarrierBuildError("effective load image evidence collections are malformed")

    data = bytes(carrier)
    manifest: dict[str, object] = {
        "schemaVersion": 2,
        "format": "macho64",
        "architecture": "arm64",
        "byteAuthority": "dcp03b2-effective-load-image",
        "requestSha256": request.request_sha256,
        "imageId": request.image_id,
        "imageUUID": request.image_uuid,
        "preferredLoadAddress": format_address(request.preferred_load_address),
        "functionEntryAddress": format_address(request.function_entry),
        "functionFileOffset": format_address(function_file_offset),
        "functionRawSha256": bytes_sha256(raw_function),
        "functionEffectiveSha256": bytes_sha256(effective_function),
        "functionAppliedPatchIds": effective.patch_ids_intersecting(
            request.function_entry,
            request.function_end,
        ),
        "effectiveLoadImageSha256": canonical_sha256(effective.output),
        "appliedPatchCount": len(patches),
        "unmappedEvidenceCount": len(unmapped),
        "carrierSha256": bytes_sha256(data),
        "carrierByteCount": len(data),
        "loadCommandCount": ncmds,
        "segmentCount": len(regions),
        "sectionCount": len(regions),
        "symbolCount": len(symbols),
        "symbolTableSha256": bytes_sha256(nlist_bytes + string_bytes),
        "sourceMappings": mappings,
    }
    manifest["manifestSha256"] = hashlib.sha256(
        canonical_json_bytes(manifest, trailing_newline=False)
    ).hexdigest()
    return CarrierArtifact(data=data, manifest=manifest, load_image=effective)
