#!/usr/bin/env python3
"""Deterministic compiler-rt arm64 function-signature generator.

The parser is intentionally Python-standard-library-only. Apple tooling is used
as an independent oracle by the test/refresh workflow, never as parser input.
"""

from __future__ import annotations

from dataclasses import dataclass, replace
from collections import Counter
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import struct
import subprocess
import tempfile
import zlib


CPU_TYPE_ARM64 = 0x0100_000C
CPU_SUBTYPE_ARM64_ALL = 0
CPU_SUBTYPE_MASK = 0xFF00_0000
FAT_MAGIC = 0xCAFE_BABE
FAT_CIGAM = 0xBEBA_FECA
FAT_MAGIC_64 = 0xCAFE_BABF
FAT_CIGAM_64 = 0xBFBA_FECA
MH_MAGIC_64 = 0xFEED_FACF
MH_OBJECT = 1
LC_SEGMENT_64 = 0x19
LC_SYMTAB = 0x2
N_STAB = 0xE0
N_TYPE = 0x0E
N_UNDF = 0x00
N_SECT = 0x0E
N_EXT = 0x01
N_PEXT = 0x10
SUPPORTED_ARM64_TEXT_RELOCATIONS = frozenset({2, 3, 4, 5, 6, 10})
ARM64_RELOC_BRANCH26 = 2
ARM64_RELOC_ADDEND = 10
ARM64_RELOC_ADDEND_TARGETS = frozenset({2, 3, 4})
MAX_FUNCTION_LENGTH = 1024 * 1024
UINT64_MAX = (1 << 64) - 1


class ParseError(ValueError):
    """Raised when a container violates a required structural invariant."""


class CheckpointStop(RuntimeError):
    """Injected smoke-test stop after a durable member checkpoint."""


@dataclass(frozen=True)
class FatSlice:
    cpu_type: int
    cpu_subtype: int
    offset: int
    size: int
    data: bytes


@dataclass(frozen=True)
class ArchiveMember:
    name: str
    header_offset: int
    data_offset: int
    stored_size: int
    data: bytes


@dataclass(frozen=True)
class RanlibEntry:
    name: str
    member_header_offset: int


@dataclass(frozen=True)
class TextSection:
    address: int
    file_offset: int
    relocation_offset: int
    relocation_count: int
    section_index: int
    bytes: bytes


@dataclass(frozen=True)
class TextSymbol:
    name: str
    value: int
    is_external: bool
    is_private_external: bool


@dataclass(frozen=True)
class RelocationSite:
    instruction_offset: int
    kinds: tuple[int, ...]
    external_branch_names: tuple[str, ...]


@dataclass(frozen=True)
class RelocationIssue:
    reason: str
    instruction_offset: int | None


@dataclass(frozen=True)
class MachOObject:
    member_name: str
    member_header_offset: int
    raw_cpu_type: int
    raw_cpu_subtype: int
    text: TextSection
    boundary_symbols: tuple[TextSymbol, ...]
    external_names_by_address: dict[int, tuple[str, ...]]
    defined_names: tuple[str, ...]
    relocation_sites: tuple[RelocationSite, ...]
    relocation_issues: tuple[RelocationIssue, ...]


@dataclass(frozen=True)
class FunctionAtom:
    member_name: str
    member_header_offset: int
    name: str
    start_address: int
    bytes: bytes
    relocation_sites: tuple[RelocationSite, ...]


@dataclass(frozen=True)
class DropRecord:
    reason: str
    member_name: str
    start_address: int
    names: tuple[str, ...]


@dataclass(frozen=True)
class MaskedPattern:
    bytes: bytes
    mask: bytes


@dataclass(frozen=True)
class ChecksumSpan:
    offset: int
    byte_count: int
    crc32: int


@dataclass(frozen=True)
class TailByteRun:
    offset: int
    bytes: bytes
    mask: bytes


@dataclass(frozen=True)
class ImportedReference:
    instruction_offset: int
    symbol_name: str


@dataclass(frozen=True)
class SignatureRecord:
    name: str
    library_name: str
    total_length: int
    prefix: MaskedPattern
    checksum: ChecksumSpan
    tail_runs: tuple[TailByteRun, ...]
    references: tuple[ImportedReference, ...]


@dataclass(frozen=True)
class DerivationResult:
    signature: SignatureRecord | None
    drop_reason: str | None


@dataclass(frozen=True)
class GeneratedArtifacts:
    swift_source: bytes
    oracle_fixture_json: bytes
    manifest_json: bytes
    rejections_json: bytes


def select_arm64_all_slice(data: bytes) -> FatSlice:
    if len(data) < 8:
        raise ParseError("fat header is truncated")
    magic = struct.unpack_from(">I", data, 0)[0]
    layouts = {
        FAT_MAGIC: (">", "IIIII", 20),
        FAT_CIGAM: ("<", "IIIII", 20),
        FAT_MAGIC_64: (">", "IIQQII", 32),
        FAT_CIGAM_64: ("<", "IIQQII", 32),
    }
    try:
        endian, arch_format, arch_size = layouts[magic]
    except KeyError as error:
        raise ParseError("expected a supported Mach-O fat container") from error
    count = struct.unpack_from(f"{endian}I", data, 4)[0]
    headers_end = 8 + count * arch_size
    if headers_end > len(data):
        raise ParseError("fat architecture table is truncated")

    matches = []
    slice_ranges = []
    for index in range(count):
        values = struct.unpack_from(f"{endian}{arch_format}", data, 8 + index * arch_size)
        cpu_type, cpu_subtype, offset, size, alignment = values[:5]
        end = offset + size
        if end < offset or offset < headers_end or end > len(data):
            raise ParseError(f"fat slice {index} is out of bounds")
        if alignment > 63 or offset % (1 << alignment) != 0:
            raise ParseError(f"fat slice {index} violates its declared alignment")
        slice_ranges.append((offset, end, index))
        normalized_subtype = cpu_subtype & ~CPU_SUBTYPE_MASK
        if cpu_type == CPU_TYPE_ARM64 and normalized_subtype == CPU_SUBTYPE_ARM64_ALL:
            matches.append(FatSlice(cpu_type, cpu_subtype, offset, size, data[offset:end]))

    for previous, current in zip(sorted(slice_ranges), sorted(slice_ranges)[1:]):
        if current[0] < previous[1]:
            raise ParseError(f"fat slices {previous[2]} and {current[2]} overlap")
    if len(matches) != 1:
        raise ParseError(f"expected exactly one arm64-all slice, found {len(matches)}")
    return matches[0]


def _parse_decimal(field: bytes, label: str) -> int:
    stripped = field.rstrip(b" ")
    if not stripped or any(byte < ord("0") or byte > ord("9") for byte in stripped):
        raise ParseError(f"archive {label} is not an unsigned decimal integer")
    return int(stripped)


def parse_bsd_archive(data: bytes) -> list[ArchiveMember]:
    if not data.startswith(b"!<arch>\n"):
        raise ParseError("expected a BSD archive")

    members = []
    cursor = 8
    while cursor < len(data):
        header_offset = cursor
        if cursor + 60 > len(data):
            raise ParseError("archive member header is truncated")
        header = data[cursor : cursor + 60]
        if header[58:60] != b"`\n":
            raise ParseError("archive member header has an invalid trailer")
        stored_size = _parse_decimal(header[48:58], "member size")
        body_offset = cursor + 60
        body_end = body_offset + stored_size
        if body_end < body_offset or body_end > len(data):
            raise ParseError("archive member body is out of bounds")

        raw_name = header[:16].decode("ascii", errors="strict").rstrip(" ")
        payload_offset = body_offset
        if raw_name.startswith("#1/"):
            name_size = _parse_decimal(raw_name[3:].encode("ascii"), "extended name size")
            if name_size > stored_size:
                raise ParseError("archive extended name exceeds member size")
            encoded_name = data[body_offset : body_offset + name_size]
            terminator = encoded_name.find(b"\0")
            if terminator < 0:
                name_bytes = encoded_name
            else:
                if any(encoded_name[terminator + 1 :]):
                    raise ParseError("archive extended-name padding is nonzero")
                name_bytes = encoded_name[:terminator]
            payload_offset += name_size
        else:
            if raw_name.startswith(("/", "//")):
                raise ParseError("GNU archive names are unsupported")
            name_bytes = raw_name.removesuffix("/").encode("ascii")
        if not name_bytes:
            raise ParseError("archive member name is empty")
        try:
            name = name_bytes.decode("utf-8")
        except UnicodeDecodeError as error:
            raise ParseError("archive member name is not UTF-8") from error

        members.append(
            ArchiveMember(
                name=name,
                header_offset=header_offset,
                data_offset=payload_offset,
                stored_size=stored_size,
                data=data[payload_offset:body_end],
            )
        )
        cursor = body_end
        if stored_size % 2:
            if cursor >= len(data):
                raise ParseError("archive member padding is truncated")
            if data[cursor : cursor + 1] != b"\n":
                raise ParseError("archive member padding is not a newline")
            cursor += 1

    return members


def parse_ranlib(data: bytes, *, valid_member_offsets: set[int]) -> list[RanlibEntry]:
    if len(data) < 8:
        raise ParseError("ranlib table is truncated")
    table_size = struct.unpack_from("<I", data, 0)[0]
    if table_size % 8:
        raise ParseError("ranlib table size is not entry-aligned")
    string_size_offset = 4 + table_size
    if string_size_offset + 4 > len(data):
        raise ParseError("ranlib entry table is out of bounds")
    string_size = struct.unpack_from("<I", data, string_size_offset)[0]
    strings_offset = string_size_offset + 4
    if strings_offset + string_size != len(data):
        raise ParseError("ranlib string table size does not match the member")
    strings = data[strings_offset:]

    entries = []
    for offset in range(4, string_size_offset, 8):
        string_index, member_offset = struct.unpack_from("<II", data, offset)
        if string_index >= len(strings):
            raise ParseError("ranlib string index is out of bounds")
        if string_index > 0 and strings[string_index - 1] != 0:
            raise ParseError("ranlib string index is not the start of a name")
        terminator = strings.find(b"\0", string_index)
        if terminator < 0:
            raise ParseError("ranlib name is not NUL-terminated")
        try:
            name = strings[string_index:terminator].decode("utf-8")
        except UnicodeDecodeError as error:
            raise ParseError("ranlib name is not UTF-8") from error
        if not name:
            raise ParseError("ranlib name is empty")
        if member_offset not in valid_member_offsets:
            raise ParseError("ranlib entry does not reference a member header")
        entries.append(RanlibEntry(name, member_offset))
    return entries


def _fixed_name(data: bytes) -> str:
    return data.split(b"\0", 1)[0].decode("ascii", errors="strict")


def _is_temporary_symbol(name: str) -> bool:
    return bool(name) and name[0] in ("L", "l")


def _checked_range(offset: int, size: int, limit: int, label: str) -> tuple[int, int]:
    end = offset + size
    if offset < 0 or size < 0 or end < offset or end > limit:
        raise ParseError(f"{label} is out of bounds")
    return offset, end


def parse_macho_object(
    data: bytes, *, member_name: str, member_header_offset: int
) -> MachOObject:
    if len(data) < 32:
        raise ParseError(f"{member_name}: Mach-O header is truncated")
    magic, cpu_type, cpu_subtype, file_type, command_count, commands_size, _flags, _reserved = (
        struct.unpack_from("<IIIIIIII", data, 0)
    )
    if magic != MH_MAGIC_64:
        raise ParseError(f"{member_name}: expected a little-endian 64-bit Mach-O")
    if (
        cpu_type != CPU_TYPE_ARM64
        or cpu_subtype & ~CPU_SUBTYPE_MASK != CPU_SUBTYPE_ARM64_ALL
    ):
        raise ParseError(f"{member_name}: expected arm64-all Mach-O object")
    if file_type != MH_OBJECT:
        raise ParseError(f"{member_name}: expected MH_OBJECT")
    _, commands_end = _checked_range(32, commands_size, len(data), "load-command table")

    cursor = 32
    section_index = 0
    text_section = None
    symtab = None
    for _ in range(command_count):
        if cursor + 8 > commands_end:
            raise ParseError(f"{member_name}: load command is truncated")
        command, command_size = struct.unpack_from("<II", data, cursor)
        if command_size < 8 or cursor + command_size > commands_end:
            raise ParseError(f"{member_name}: load command size is invalid")
        if command == LC_SEGMENT_64:
            if command_size < 72:
                raise ParseError(f"{member_name}: LC_SEGMENT_64 is truncated")
            section_count = struct.unpack_from("<I", data, cursor + 64)[0]
            if 72 + section_count * 80 > command_size:
                raise ParseError(f"{member_name}: section table is truncated")
            for section_ordinal in range(section_count):
                section_index += 1
                offset = cursor + 72 + section_ordinal * 80
                section_name = _fixed_name(data[offset : offset + 16])
                segment_name = _fixed_name(data[offset + 16 : offset + 32])
                address, size = struct.unpack_from("<QQ", data, offset + 32)
                file_offset, _alignment, relocation_offset, relocation_count = struct.unpack_from(
                    "<IIII", data, offset + 48
                )
                if segment_name == "__TEXT" and section_name == "__text":
                    if text_section is not None:
                        raise ParseError(f"{member_name}: duplicate __TEXT,__text section")
                    if address > UINT64_MAX - size:
                        raise ParseError(
                            f"{member_name}: __text address range overflows UInt64"
                        )
                    start, end = _checked_range(file_offset, size, len(data), "__text bytes")
                    if relocation_count:
                        _checked_range(
                            relocation_offset,
                            relocation_count * 8,
                            len(data),
                            "__text relocations",
                        )
                    text_section = TextSection(
                        address=address,
                        file_offset=file_offset,
                        relocation_offset=relocation_offset,
                        relocation_count=relocation_count,
                        section_index=section_index,
                        bytes=data[start:end],
                    )
        elif command == LC_SYMTAB:
            if command_size != 24 or symtab is not None:
                raise ParseError(f"{member_name}: invalid LC_SYMTAB")
            symtab = struct.unpack_from("<IIII", data, cursor + 8)
        cursor += command_size
    if cursor != commands_end:
        raise ParseError(f"{member_name}: load-command size does not match header")
    if text_section is None or symtab is None:
        raise ParseError(f"{member_name}: missing __text or LC_SYMTAB")

    symbol_offset, symbol_count, string_offset, string_size = symtab
    _checked_range(symbol_offset, symbol_count * 16, len(data), "symbol table")
    string_start, string_end = _checked_range(string_offset, string_size, len(data), "string table")
    strings = data[string_start:string_end]
    text_end_address = text_section.address + len(text_section.bytes)
    raw_symbols = []
    for index in range(symbol_count):
        string_index, symbol_type, symbol_section, description, value = struct.unpack_from(
            "<IBBHQ", data, symbol_offset + index * 16
        )
        if string_index >= len(strings):
            raise ParseError(f"{member_name}: symbol string index is out of bounds")
        terminator = strings.find(b"\0", string_index)
        if terminator < 0:
            raise ParseError(f"{member_name}: symbol name is not NUL-terminated")
        try:
            name = strings[string_index:terminator].decode("utf-8")
        except UnicodeDecodeError as error:
            raise ParseError(f"{member_name}: symbol name is not UTF-8") from error
        raw_symbols.append((name, symbol_type, symbol_section, description, value))

    symbols = []
    external_names = {}
    for name, symbol_type, symbol_section, _description, value in raw_symbols:
        if symbol_type & N_STAB or symbol_type & N_TYPE != N_SECT:
            continue
        if not name or _is_temporary_symbol(name):
            continue
        if symbol_section != text_section.section_index:
            continue
        if not (text_section.address <= value < text_end_address):
            raise ParseError(f"{member_name}: __text symbol value is out of bounds")
        is_external = bool(symbol_type & N_EXT)
        is_private_external = bool(symbol_type & N_PEXT)
        symbol = TextSymbol(name, value, is_external, is_private_external)
        symbols.append(symbol)
        if is_external or is_private_external:
            external_names.setdefault(value, []).append(name)

    symbols.sort(key=lambda symbol: (symbol.value, symbol.name))
    frozen_external_names = {
        address: tuple(sorted(set(names))) for address, names in sorted(external_names.items())
    }
    defined_names = tuple(
        sorted(
            {
                name
                for name, symbol_type, _symbol_section, _description, _value in raw_symbols
                if name and not symbol_type & N_STAB and symbol_type & N_TYPE != N_UNDF
            }
        )
    )
    relocation_sites = {}
    relocation_issues = []
    raw_relocations = []
    for index in range(text_section.relocation_count):
        relocation_offset = text_section.relocation_offset + index * 8
        address_bits, attributes = struct.unpack_from("<II", data, relocation_offset)
        raw_relocations.append((address_bits, attributes))

    for index, (address_bits, attributes) in enumerate(raw_relocations):
        if address_bits & 0x8000_0000:
            relocation_issues.append(RelocationIssue("scattered-or-negative-relocation", None))
            continue
        address = address_bits
        symbol_index = attributes & 0x00FF_FFFF
        is_pc_relative = bool((attributes >> 24) & 1)
        width_code = (attributes >> 25) & 0x3
        is_external = bool((attributes >> 27) & 1)
        kind = (attributes >> 28) & 0xF
        if kind not in SUPPORTED_ARM64_TEXT_RELOCATIONS:
            issue_offset = address if address < len(text_section.bytes) else None
            relocation_issues.append(RelocationIssue("unsupported-relocation-type", issue_offset))
            continue
        if width_code != 2 or address % 4 or address + 4 > len(text_section.bytes):
            issue_offset = address if address < len(text_section.bytes) else None
            relocation_issues.append(RelocationIssue("malformed-relocation", issue_offset))
            continue
        expected_flags = {
            2: (True, True),
            3: (True, True),
            4: (False, True),
            5: (True, True),
            6: (False, True),
            10: (False, False),
        }
        if (is_pc_relative, is_external) != expected_flags[kind]:
            relocation_issues.append(RelocationIssue("invalid-relocation-flags", address))
            continue
        if kind == ARM64_RELOC_ADDEND:
            paired = index + 1 < len(raw_relocations)
            if paired:
                next_address_bits, next_attributes = raw_relocations[index + 1]
                next_kind = (next_attributes >> 28) & 0xF
                paired = (
                    not next_address_bits & 0x8000_0000
                    and next_address_bits == address
                    and next_kind in ARM64_RELOC_ADDEND_TARGETS
                )
            if not paired:
                relocation_issues.append(RelocationIssue("malformed-addend-pair", address))
                continue
        branch_name = None
        if is_external and kind != 10:
            if symbol_index >= len(raw_symbols):
                relocation_issues.append(RelocationIssue("invalid-relocation-symbol", address))
                continue
            branch_name = raw_symbols[symbol_index][0]
            if not branch_name:
                relocation_issues.append(RelocationIssue("invalid-relocation-symbol", address))
                continue
        entry = relocation_sites.setdefault(address, {"kinds": set(), "branch_names": set()})
        entry["kinds"].add(kind)
        if kind == ARM64_RELOC_BRANCH26 and branch_name is not None:
            target_type = raw_symbols[symbol_index][1]
            target_section = raw_symbols[symbol_index][2]
            if target_type & N_TYPE == N_UNDF and target_type & N_EXT and target_section == 0:
                entry["branch_names"].add(branch_name)

    frozen_relocations = tuple(
        RelocationSite(
            instruction_offset=address,
            kinds=tuple(sorted(entry["kinds"])),
            external_branch_names=tuple(sorted(entry["branch_names"])),
        )
        for address, entry in sorted(relocation_sites.items())
    )
    return MachOObject(
        member_name=member_name,
        member_header_offset=member_header_offset,
        raw_cpu_type=cpu_type,
        raw_cpu_subtype=cpu_subtype,
        text=text_section,
        boundary_symbols=tuple(symbols),
        external_names_by_address=frozen_external_names,
        defined_names=defined_names,
        relocation_sites=frozen_relocations,
        relocation_issues=tuple(
            sorted(
                relocation_issues,
                key=lambda issue: (
                    issue.instruction_offset is not None,
                    issue.instruction_offset if issue.instruction_offset is not None else -1,
                    issue.reason,
                ),
            )
        ),
    )


def discover_function_atoms(
    objects: list[MachOObject], *, ranlib_names_by_member: dict[int, set[str]]
) -> tuple[list[FunctionAtom], list[DropRecord]]:
    atoms = []
    drops = []
    for obj in sorted(objects, key=lambda item: (item.member_name, item.member_header_offset)):
        boundaries = sorted({symbol.value for symbol in obj.boundary_symbols})
        section_end = obj.text.address + len(obj.text.bytes)
        for index, start_address in enumerate(boundaries):
            names = obj.external_names_by_address.get(start_address, ())
            if not names:
                continue
            if len(names) != 1:
                drops.append(
                    DropRecord(
                        reason="same-address-alias",
                        member_name=obj.member_name,
                        start_address=start_address,
                        names=names,
                    )
                )
                continue
            name = names[0]
            if name not in ranlib_names_by_member.get(obj.member_header_offset, set()):
                drops.append(
                    DropRecord(
                        reason="missing-ranlib-evidence",
                        member_name=obj.member_name,
                        start_address=start_address,
                        names=(name,),
                    )
                )
                continue
            end_address = boundaries[index + 1] if index + 1 < len(boundaries) else section_end
            start_offset = start_address - obj.text.address
            end_offset = end_address - obj.text.address
            if (
                start_address % 4
                or end_address % 4
                or end_offset <= start_offset
                or start_offset < 0
                or end_offset > len(obj.text.bytes)
            ):
                drops.append(
                    DropRecord(
                        reason="malformed-range",
                        member_name=obj.member_name,
                        start_address=start_address,
                        names=(name,),
                    )
                )
                continue
            atom_relocations = []
            malformed_relocation = False
            for site in obj.relocation_sites:
                if start_offset <= site.instruction_offset < end_offset:
                    if site.instruction_offset + 4 > end_offset:
                        malformed_relocation = True
                        break
                    atom_relocations.append(
                        RelocationSite(
                            instruction_offset=site.instruction_offset - start_offset,
                            kinds=site.kinds,
                            external_branch_names=site.external_branch_names,
                        )
                    )
            if malformed_relocation:
                drops.append(
                    DropRecord(
                        reason="relocation-crosses-boundary",
                        member_name=obj.member_name,
                        start_address=start_address,
                        names=(name,),
                    )
                )
                continue
            relevant_issues = [
                issue
                for issue in obj.relocation_issues
                if issue.instruction_offset is None
                or start_offset <= issue.instruction_offset < end_offset
            ]
            if relevant_issues:
                issue = relevant_issues[0]
                drops.append(
                    DropRecord(
                        reason=issue.reason,
                        member_name=obj.member_name,
                        start_address=start_address,
                        names=(name,),
                    )
                )
                continue
            atoms.append(
                FunctionAtom(
                    member_name=obj.member_name,
                    member_header_offset=obj.member_header_offset,
                    name=name,
                    start_address=start_address,
                    bytes=obj.text.bytes[start_offset:end_offset],
                    relocation_sites=tuple(atom_relocations),
                )
            )

    atoms.sort(key=lambda atom: (atom.name, atom.member_name, atom.start_address))
    drops.sort(key=lambda drop: (drop.member_name, drop.start_address, drop.reason, drop.names))
    return atoms, drops


def derive_signature(
    atom: FunctionAtom, *, archive_defined_names: set[str], library_name: str
) -> DerivationResult:
    if not _valid_schema_name(atom.name):
        return DerivationResult(None, "invalid-function-name")
    if not _valid_schema_name(library_name):
        return DerivationResult(None, "invalid-library-name")
    total_length = len(atom.bytes)
    if total_length <= 0 or total_length % 4:
        return DerivationResult(None, "malformed-range")
    if total_length > MAX_FUNCTION_LENGTH:
        return DerivationResult(None, "length-exceeds-schema-limit")

    variable = bytearray(total_length)
    references_by_offset = {}
    for site in atom.relocation_sites:
        if site.instruction_offset % 4 or site.instruction_offset + 4 > total_length:
            return DerivationResult(None, "malformed-relocation")
        variable[site.instruction_offset : site.instruction_offset + 4] = b"\x01" * 4
        if len(site.external_branch_names) > 1:
            return DerivationResult(None, "conflicting-imported-reference")
        eligible_names = tuple(
            name for name in site.external_branch_names if name not in archive_defined_names
        )
        if len(eligible_names) > 1:
            return DerivationResult(None, "conflicting-imported-reference")
        if eligible_names:
            references_by_offset.setdefault(site.instruction_offset, set()).add(eligible_names[0])

    prefix_length = min(total_length, 32)
    prefix_bytes = bytearray(atom.bytes[:prefix_length])
    prefix_mask = bytearray(b"\xff" * prefix_length)
    for offset in range(prefix_length):
        if variable[offset]:
            prefix_bytes[offset] = 0
            prefix_mask[offset] = 0

    if total_length <= 32:
        checksum = ChecksumSpan(total_length, 0, 0)
    else:
        checksum_end = 32
        while checksum_end < total_length and not variable[checksum_end]:
            checksum_end += 1
        if checksum_end == 32:
            return DerivationResult(None, "unstable-checksum")
        checksum_bytes = atom.bytes[32:checksum_end]
        checksum = ChecksumSpan(32, len(checksum_bytes), zlib.crc32(checksum_bytes) & 0xFFFF_FFFF)

    tail_runs = []
    tail_bytes_remaining = 32
    cursor = checksum.offset + checksum.byte_count
    while cursor < total_length and len(tail_runs) < 8 and tail_bytes_remaining:
        while cursor < total_length and variable[cursor]:
            cursor += 1
        if cursor >= total_length:
            break
        run_start = cursor
        while cursor < total_length and not variable[cursor]:
            cursor += 1
        run_end = min(cursor, run_start + tail_bytes_remaining)
        run_bytes = atom.bytes[run_start:run_end]
        if run_bytes:
            tail_runs.append(TailByteRun(run_start, run_bytes, b"\xff" * len(run_bytes)))
            tail_bytes_remaining -= len(run_bytes)

    references = []
    for offset, names in sorted(references_by_offset.items()):
        if len(names) != 1:
            return DerivationResult(None, "conflicting-imported-reference")
        references.append(ImportedReference(offset, next(iter(names))))
    if len(references) > 8:
        return DerivationResult(None, "too-many-imported-references")

    exact_prefix_bytes = sum(1 for byte in prefix_mask if byte == 0xFF)
    evidence_bits = (
        exact_prefix_bytes * 8
        + min(checksum.byte_count * 8, 32)
        + sum(len(run.bytes) * 8 for run in tail_runs)
    )
    if evidence_bits < 128:
        return DerivationResult(None, "weak-evidence")
    if not any(
        offset + 4 <= prefix_length and prefix_mask[offset : offset + 4] == b"\xff" * 4
        for offset in range(0, prefix_length, 4)
    ):
        return DerivationResult(None, "missing-prefix-anchor")

    return DerivationResult(
        SignatureRecord(
            name=atom.name,
            library_name=library_name,
            total_length=total_length,
            prefix=MaskedPattern(bytes(prefix_bytes), bytes(prefix_mask)),
            checksum=checksum,
            tail_runs=tuple(tail_runs),
            references=tuple(references),
        ),
        None,
    )


def _valid_schema_name(value: str) -> bool:
    return bool(value) and value == value.strip() and not any(
        ord(character) < 0x20 or ord(character) == 0x7F for character in value
    )


def _canonical_json(value) -> bytes:
    return (json.dumps(value, sort_keys=True, indent=2, ensure_ascii=True) + "\n").encode("utf-8")


def _swift_string(value: str) -> str:
    if any(ord(character) < 0x20 or ord(character) == 0x7F for character in value):
        raise ParseError("Swift string contains a control character")
    rendered = value.replace("\\", "\\\\").replace('"', '\\"')
    return f'"{rendered}"'


def _swift_bytes(value: bytes) -> str:
    return "[" + ", ".join(f"0x{byte:02x}" for byte in value) + "]"


def render_swift_corpus(signatures: list[SignatureRecord]) -> bytes:
    lines = [
        "// Generated by Scripts/function-signatures/generate_compiler_rt_signatures.py.",
        "// Do not edit by hand.",
        "",
        "enum FunctionSignatureCorpus {",
        "    static let database: FunctionSignatureDatabase = FunctionSignatureDatabase(",
        "        schemaVersion: FunctionSignatureDatabase.currentSchemaVersion,",
        "        signatures: [",
    ]
    for signature in signatures:
        lines.extend(
            [
                "            FunctionSignature(",
                "                architecture: .arm64,",
                f"                name: {_swift_string(signature.name)},",
                f"                libraryName: {_swift_string(signature.library_name)},",
                f"                totalLength: {signature.total_length},",
                "                prefix: FunctionSignatureMaskedPattern(",
                f"                    bytes: {_swift_bytes(signature.prefix.bytes)},",
                f"                    comparisonMask: {_swift_bytes(signature.prefix.mask)}",
                "                ),",
                "                checksum: FunctionSignatureChecksumSpan(",
                f"                    offset: {signature.checksum.offset},",
                f"                    byteCount: {signature.checksum.byte_count},",
                f"                    crc32: 0x{signature.checksum.crc32:08x}",
                "                ),",
                "                collisionTail: FunctionSignatureCollisionTail(",
                "                    byteRuns: [",
            ]
        )
        for run in signature.tail_runs:
            lines.extend(
                [
                    "                        FunctionSignatureMaskedByteRun(",
                    f"                            offset: {run.offset},",
                    f"                            bytes: {_swift_bytes(run.bytes)},",
                    f"                            comparisonMask: {_swift_bytes(run.mask)}",
                    "                        ),",
                ]
            )
        lines.extend(["                    ],", "                    importedReferences: ["])
        for reference in signature.references:
            lines.extend(
                [
                    "                        FunctionSignatureImportedReference(",
                    f"                            instructionOffset: {reference.instruction_offset},",
                    f"                            expectedSymbolName: {_swift_string(reference.symbol_name)}",
                    "                        ),",
                ]
            )
        lines.extend(
            [
                "                    ]",
                "                )",
                "            ),",
            ]
        )
    lines.extend(["        ]", "    )", "}", ""])
    return "\n".join(lines).encode("utf-8")


def _signature_sort_key(signature: SignatureRecord):
    return (
        signature.library_name,
        signature.name,
        signature.total_length,
        signature.prefix.bytes,
        signature.prefix.mask,
        signature.checksum.offset,
        signature.checksum.byte_count,
        signature.checksum.crc32,
        tuple((run.offset, run.bytes, run.mask) for run in signature.tail_runs),
        tuple((reference.instruction_offset, reference.symbol_name) for reference in signature.references),
    )


def _predicate_key(signature: SignatureRecord):
    return (
        signature.total_length,
        signature.prefix.bytes,
        signature.prefix.mask,
        signature.checksum.offset,
        signature.checksum.byte_count,
        signature.checksum.crc32,
        tuple((run.offset, run.bytes, run.mask) for run in signature.tail_runs),
        tuple((reference.instruction_offset, reference.symbol_name) for reference in signature.references),
    )


def filter_predicate_collisions(
    records: list[tuple[SignatureRecord, FunctionAtom]],
) -> tuple[list[tuple[SignatureRecord, FunctionAtom]], list[DropRecord]]:
    ordered_records = sorted(
        records,
        key=lambda item: (
            item[0].library_name,
            item[0].name,
            item[1].member_name,
            item[1].start_address,
        ),
    )
    reasons = {}
    exact_groups = {}
    for index, (signature, _atom) in enumerate(ordered_records):
        exact_groups.setdefault(_predicate_key(signature), []).append(index)
    for indices in exact_groups.values():
        if len(indices) < 2:
            continue
        identities = {
            (ordered_records[index][0].name, ordered_records[index][0].library_name)
            for index in indices
        }
        reason = "predicate-collision" if len(identities) > 1 else "duplicate-predicate"
        for index in indices:
            reasons[index] = reason

    for _candidate_signature, candidate_atom in ordered_records:
        matching_indices = [
            index
            for index, (signature, _source_atom) in enumerate(ordered_records)
            if _source_candidate_matches(signature, candidate_atom)
        ]
        identities = {
            (ordered_records[index][0].name, ordered_records[index][0].library_name)
            for index in matching_indices
        }
        if len(identities) > 1:
            for index in matching_indices:
                reasons[index] = "predicate-collision"

    accepted = [record for index, record in enumerate(ordered_records) if index not in reasons]
    drops = []
    for index, reason in sorted(reasons.items()):
        signature, atom = ordered_records[index]
        drops.append(
            DropRecord(
                reason=reason,
                member_name=atom.member_name,
                start_address=atom.start_address,
                names=(signature.name,),
            )
        )
    accepted.sort(key=lambda item: _signature_sort_key(item[0]))
    drops.sort(key=lambda drop: (drop.member_name, drop.start_address, drop.reason, drop.names))
    return accepted, drops


def _source_candidate_matches(signature: SignatureRecord, atom: FunctionAtom) -> bool:
    candidate = atom.bytes
    if len(candidate) != signature.total_length:
        return False
    for index, mask in enumerate(signature.prefix.mask):
        if candidate[index] & mask != signature.prefix.bytes[index]:
            return False
    checksum = signature.checksum
    if checksum.byte_count:
        end = checksum.offset + checksum.byte_count
        if end > len(candidate) or zlib.crc32(candidate[checksum.offset:end]) & 0xFFFF_FFFF != checksum.crc32:
            return False
    for run in signature.tail_runs:
        end = run.offset + len(run.bytes)
        if end > len(candidate):
            return False
        if any(candidate[run.offset + index] & mask != run.bytes[index] for index, mask in enumerate(run.mask)):
            return False
    reference_names = {
        site.instruction_offset: site.external_branch_names for site in atom.relocation_sites
    }
    for reference in signature.references:
        if reference_names.get(reference.instruction_offset) != (reference.symbol_name,):
            return False
    return True


def symbol_range_witnesses(objects: list[MachOObject]) -> list[tuple[tuple[str, ...], FunctionAtom]]:
    """Every symbol-delimited __text range, static functions included, with all its names.

    Records are derived only from exported, ranlib-listed atoms, so the collision filter above
    never sees a static function. A static helper byte-identical to an exported wrapper would
    then match the wrapper's record once linked and be named wrongly (H18,
    the compiler-runtime signature contract)."""
    witnesses = []
    for obj in sorted(objects, key=lambda item: (item.member_name, item.member_header_offset)):
        boundaries = sorted({symbol.value for symbol in obj.boundary_symbols})
        names_at: dict[int, set[str]] = {}
        for symbol in obj.boundary_symbols:
            names_at.setdefault(symbol.value, set()).add(symbol.name)
        section_end = obj.text.address + len(obj.text.bytes)
        for index, start in enumerate(boundaries):
            end = boundaries[index + 1] if index + 1 < len(boundaries) else section_end
            start_offset = start - obj.text.address
            end_offset = end - obj.text.address
            if start % 4 or end % 4 or end_offset <= start_offset:
                continue
            names = tuple(sorted(names_at[start]))
            witnesses.append((names, FunctionAtom(
                member_name=obj.member_name,
                member_header_offset=obj.member_header_offset,
                name=names[0],
                start_address=start,
                bytes=obj.text.bytes[start_offset:end_offset],
                relocation_sites=(),
            )))
    return witnesses


def filter_witness_collisions(
    records: list[tuple[SignatureRecord, FunctionAtom]],
    witnesses: list[tuple[tuple[str, ...], FunctionAtom]],
) -> tuple[list[tuple[SignatureRecord, FunctionAtom]], list[DropRecord]]:
    """Drop a record whose byte predicate matches any differently named range in the archive.

    Imported-reference checks are ignored for witnesses: a twin's call to a function defined in
    its own object carries no reference name in the object, yet may be named once linked."""
    by_length: dict[int, list[tuple[tuple[str, ...], FunctionAtom]]] = {}
    for names, atom in witnesses:
        by_length.setdefault(len(atom.bytes), []).append((names, atom))
    accepted = []
    drops = []
    for signature, atom in records:
        byte_predicate = replace(signature, references=())
        twin = next(
            (
                (names, witness)
                for names, witness in by_length.get(signature.total_length, ())
                if signature.name not in names and _source_candidate_matches(byte_predicate, witness)
            ),
            None,
        )
        if twin is None:
            accepted.append((signature, atom))
        else:
            drops.append(DropRecord("witness-collision", atom.member_name, atom.start_address, (signature.name,)))
    return accepted, drops


def _object_checkpoint_record(obj: MachOObject) -> dict:
    return {
        "boundary_symbol_count": len(obj.boundary_symbols),
        "defined_name_count": len(obj.defined_names),
        "member_header_offset": obj.member_header_offset,
        "raw_cpu_subtype": obj.raw_cpu_subtype,
        "raw_cpu_type": obj.raw_cpu_type,
        "relocation_site_count": len(obj.relocation_sites),
        "relocation_issue_count": len(obj.relocation_issues),
        "text_byte_count": len(obj.text.bytes),
    }


def _atomic_write_bytes(path: Path, value: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="wb",
            dir=path.parent,
            prefix=f".{path.name}.",
            suffix=".tmp",
            delete=False,
        ) as output:
            temporary = Path(output.name)
            output.write(value)
        os.replace(temporary, path)
        temporary = None
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def _write_checkpoint(path: Path, value: dict) -> None:
    _atomic_write_bytes(path, _canonical_json(value))


def _parse_objects_with_checkpoint(
    object_members: list[ArchiveMember],
    *,
    checkpoint_path: Path | None,
    stop_after_members: int | None,
    source_sha256: str,
    selected: FatSlice,
) -> list[MachOObject]:
    if checkpoint_path is not None:
        repository_root = Path(__file__).resolve().parents[2]
        try:
            checkpoint_path.resolve().relative_to(repository_root)
        except ValueError:
            pass
        else:
            raise ParseError("checkpoint path must be outside the repository")
    metadata = {
        "input_sha256": source_sha256,
        "normalized_cpu_subtype": selected.cpu_subtype & ~CPU_SUBTYPE_MASK,
        "raw_cpu_subtype": selected.cpu_subtype,
        "raw_cpu_type": selected.cpu_type,
        "schema_version": 1,
    }
    objects = []
    normalized_records = []
    next_member_index = 0
    if checkpoint_path is not None and checkpoint_path.exists():
        try:
            checkpoint_bytes = checkpoint_path.read_bytes()
            checkpoint = json.loads(checkpoint_bytes)
        except (OSError, ValueError, TypeError) as error:
            raise ParseError("checkpoint is not valid canonical JSON") from error
        if checkpoint_bytes != _canonical_json(checkpoint):
            raise ParseError("checkpoint JSON is not canonical")
        if not isinstance(checkpoint, dict):
            raise ParseError("checkpoint top level must be an object")
        for key, expected in metadata.items():
            actual = checkpoint.get(key)
            if type(actual) is not type(expected) or actual != expected:
                raise ParseError(f"checkpoint {key} does not match the input")
        next_member_index = checkpoint.get("next_member_index")
        normalized_records = checkpoint.get("normalized_records")
        if (
            type(next_member_index) is not int
            or not isinstance(normalized_records, list)
            or next_member_index != len(normalized_records)
            or not 0 <= next_member_index <= len(object_members)
        ):
            raise ParseError("checkpoint member progress is malformed")
        if checkpoint.get("drop_reason_counts") != {}:
            raise ParseError("checkpoint drop counts are malformed")
        for index in range(next_member_index):
            member = object_members[index]
            obj = parse_macho_object(
                member.data,
                member_name=member.name,
                member_header_offset=member.header_offset,
            )
            if _object_checkpoint_record(obj) != normalized_records[index]:
                raise ParseError("checkpoint normalized record does not match reparsed input")
            objects.append(obj)

    for index in range(next_member_index, len(object_members)):
        member = object_members[index]
        objects.append(
            parse_macho_object(
                member.data,
                member_name=member.name,
                member_header_offset=member.header_offset,
            )
        )
        next_member_index = index + 1
        normalized_records.append(_object_checkpoint_record(objects[-1]))
        if checkpoint_path is not None:
            _write_checkpoint(
                checkpoint_path,
                {
                    **metadata,
                    "drop_reason_counts": {},
                    "next_member_index": next_member_index,
                    "normalized_records": normalized_records,
                },
            )
        if (
            stop_after_members is not None
            and next_member_index >= stop_after_members
            and next_member_index < len(object_members)
        ):
            raise CheckpointStop(f"stopped after member {next_member_index}")
    return objects


def generate_artifacts(
    data: bytes,
    *,
    library_name: str,
    checkpoint_path: Path | None = None,
    stop_after_members: int | None = None,
) -> GeneratedArtifacts:
    source_sha256 = hashlib.sha256(data).hexdigest()
    selected = select_arm64_all_slice(data)
    members = parse_bsd_archive(selected.data)
    symdef_members = [member for member in members if member.name in {"__.SYMDEF", "__.SYMDEF SORTED"}]
    if len(symdef_members) != 1:
        raise ParseError(f"expected exactly one BSD ranlib member, found {len(symdef_members)}")
    object_members = [member for member in members if member not in symdef_members]
    object_offsets = {member.header_offset for member in object_members}
    ranlib_entries = parse_ranlib(symdef_members[0].data, valid_member_offsets=object_offsets)
    ranlib_names_by_member = {}
    for entry in ranlib_entries:
        ranlib_names_by_member.setdefault(entry.member_header_offset, set()).add(entry.name)

    objects = _parse_objects_with_checkpoint(
        object_members,
        checkpoint_path=checkpoint_path,
        stop_after_members=stop_after_members,
        source_sha256=source_sha256,
        selected=selected,
    )
    for obj in objects:
        if (
            obj.raw_cpu_type != selected.cpu_type
            or obj.raw_cpu_subtype != selected.cpu_subtype
        ):
            raise ParseError(f"{obj.member_name}: object CPU record disagrees with fat slice")
    archive_defined_names = {
        name for obj in objects for name in obj.defined_names
    } | {entry.name for entry in ranlib_entries}
    atoms, drops = discover_function_atoms(
        objects,
        ranlib_names_by_member=ranlib_names_by_member,
    )

    derived_records = []
    for atom in atoms:
        result = derive_signature(
            atom,
            archive_defined_names=archive_defined_names,
            library_name=library_name,
        )
        if result.signature is None:
            drops.append(
                DropRecord(
                    reason=result.drop_reason or "unknown-derivation-drop",
                    member_name=atom.member_name,
                    start_address=atom.start_address,
                    names=(atom.name,),
                )
            )
            continue
        derived_records.append((result.signature, atom))

    accepted_records, collision_drops = filter_predicate_collisions(derived_records)
    drops.extend(collision_drops)
    accepted_records, witness_drops = filter_witness_collisions(accepted_records, symbol_range_witnesses(objects))
    drops.extend(witness_drops)
    emitted = [signature for signature, _atom in accepted_records]
    fixtures = []
    for result_signature, atom in accepted_records:
        fixtures.append(
            {
                "bytes": list(atom.bytes),
                "library_name": library_name,
                "member_name": atom.member_name,
                "name": atom.name,
                "references": [
                    {
                        "instruction_offset": reference.instruction_offset,
                        "symbol_name": reference.symbol_name,
                    }
                    for reference in result_signature.references
                ],
                "start_address": atom.start_address,
            }
        )

    emitted.sort(key=_signature_sort_key)
    fixtures.sort(key=lambda fixture: (fixture["name"], fixture["member_name"], fixture["start_address"]))
    drops.sort(key=lambda drop: (drop.member_name, drop.start_address, drop.reason, drop.names))
    drop_counts = Counter(drop.reason for drop in drops)
    manifest = {
        "counts": {
            "archive_members": len(members),
            "boundary_symbols": sum(len(obj.boundary_symbols) for obj in objects),
            "candidate_atoms": len(atoms),
            "emitted_signatures": len(emitted),
            "external_start_atoms": sum(len(obj.external_names_by_address) for obj in objects),
            "mach_o_objects": len(objects),
            "ranlib_entries": len(ranlib_entries),
            "rejections": len(drops),
            "text_relocation_records": sum(obj.text.relocation_count for obj in objects),
            "text_relocation_sites": sum(len(obj.relocation_sites) for obj in objects),
        },
        "drop_reason_counts": dict(sorted(drop_counts.items())),
        "schema_version": 1,
        "selected_cpu": {
            "normalized_subtype": selected.cpu_subtype & ~CPU_SUBTYPE_MASK,
            "raw_subtype": selected.cpu_subtype,
            "raw_type": selected.cpu_type,
            "slice_offset": selected.offset,
            "slice_size": selected.size,
        },
        "source": {
            "archive_name": "libclang_rt.osx.a",
            "archive_sha256": source_sha256,
            "slice_sha256": hashlib.sha256(selected.data).hexdigest(),
        },
    }
    rejections = [
        {
            "member_name": drop.member_name,
            "names": list(drop.names),
            "reason": drop.reason,
            "start_address": drop.start_address,
        }
        for drop in drops
    ]
    return GeneratedArtifacts(
        swift_source=render_swift_corpus(emitted),
        oracle_fixture_json=_canonical_json(fixtures),
        manifest_json=_canonical_json(manifest),
        rejections_json=_canonical_json(rejections),
    )


def parse_apple_tool_evidence(
    *,
    lipo_output: str,
    archive_headers_output: str,
    nm_output: str,
    otool_output: str,
) -> dict[str, int]:
    arm64_match = re.search(
        r"architecture arm64\s+.*?\boffset\s+(\d+)\s+\bsize\s+(\d+)",
        lipo_output,
        flags=re.DOTALL,
    )
    if arm64_match is None:
        raise ParseError("lipo evidence lacks an arm64 slice record")
    archive_members = sum(
        1 for line in archive_headers_output.splitlines() if re.match(r"^\d+\s+-", line)
    )
    boundary_symbols = 0
    for line in nm_output.splitlines():
        match = re.match(r"^[0-9a-fA-F]{16}\s+[Tt]\s+(.+)$", line)
        if match is None:
            continue
        name = match.group(1)
        if name and not _is_temporary_symbol(name):
            boundary_symbols += 1
    in_text_relocations = False
    relocation_records = 0
    for line in otool_output.splitlines():
        if line.startswith("Relocation information "):
            in_text_relocations = line.startswith("Relocation information (__TEXT,__text)")
            continue
        if line.endswith("):"):
            in_text_relocations = False
            continue
        if in_text_relocations and re.match(r"^[0-9a-fA-F]{8}\s", line):
            relocation_records += 1
    return {
        "arm64_offset": int(arm64_match.group(1)),
        "arm64_size": int(arm64_match.group(2)),
        "archive_members": archive_members,
        "boundary_symbols": boundary_symbols,
        "text_relocation_records": relocation_records,
    }


def cross_check_apple_tools(archive: Path) -> dict[str, int]:
    commands = {
        "lipo_output": ["xcrun", "lipo", "-detailed_info", str(archive)],
        "archive_headers_output": [
            "xcrun",
            "llvm-objdump",
            "--macho",
            "--archive-headers",
            "--archive-member-offsets",
            "--arch=arm64",
            str(archive),
        ],
        "nm_output": ["xcrun", "nm", "-arch", "arm64", "-s", "__TEXT", "__text", str(archive)],
        "otool_output": ["xcrun", "otool", "-arch", "arm64", "-rvV", str(archive)],
    }
    outputs = {}
    for name, command in commands.items():
        try:
            completed = subprocess.run(command, check=True, capture_output=True, text=True)
        except (OSError, subprocess.CalledProcessError) as error:
            raise ParseError(f"Apple-tool oracle failed: {' '.join(command[:2])}") from error
        outputs[name] = completed.stdout
    return parse_apple_tool_evidence(**outputs)


def verify_dual_temporary_render(artifacts: GeneratedArtifacts) -> None:
    with tempfile.TemporaryDirectory() as first_dir, tempfile.TemporaryDirectory() as second_dir:
        names = {
            "swift_source": "corpus.swift",
            "oracle_fixture_json": "fixtures.json",
            "manifest_json": "manifest.json",
            "rejections_json": "rejections.json",
        }
        first_paths = {key: Path(first_dir) / value for key, value in names.items()}
        second_paths = {key: Path(second_dir) / value for key, value in names.items()}
        synchronize_artifacts(artifacts, first_paths, refresh=True)
        synchronize_artifacts(artifacts, second_paths, refresh=True)
        for key in names:
            if first_paths[key].read_bytes() != second_paths[key].read_bytes():
                raise ParseError(f"dual temporary render drifted for {key}")


def synchronize_artifacts(
    artifacts: GeneratedArtifacts,
    outputs: dict[str, Path],
    *,
    refresh: bool,
) -> list[str]:
    expected = {
        "swift_source": artifacts.swift_source,
        "oracle_fixture_json": artifacts.oracle_fixture_json,
        "manifest_json": artifacts.manifest_json,
        "rejections_json": artifacts.rejections_json,
    }
    if set(outputs) != set(expected):
        raise ValueError("artifact output mapping is incomplete")
    drift = []
    for name in sorted(expected):
        path = Path(outputs[name])
        current = path.read_bytes() if path.exists() else None
        if current == expected[name]:
            continue
        if not refresh:
            drift.append(str(path))
            continue
        _atomic_write_bytes(path, expected[name])
    return drift


def _validate_refresh_paths(
    outputs: dict[str, Path],
    *,
    archive: Path,
    checkpoint_path: Path | None,
) -> None:
    resolved_outputs = {name: Path(path).resolve() for name, path in outputs.items()}
    if len(set(resolved_outputs.values())) != len(resolved_outputs):
        raise ParseError("refresh output paths must be distinct after resolution")
    resolved_archive = Path(archive).resolve()
    if resolved_archive in resolved_outputs.values():
        raise ParseError("refresh output path aliases archive")
    if checkpoint_path is not None:
        resolved_checkpoint = Path(checkpoint_path).resolve()
        if resolved_checkpoint in resolved_outputs.values():
            raise ParseError("refresh output path aliases checkpoint")


def _argument_parser() -> argparse.ArgumentParser:
    repository_root = Path(__file__).resolve().parents[2]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--archive", required=True, type=Path)
    parser.add_argument("--expected-sha256", required=True)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--check", action="store_true", help="compare only; never write outputs")
    mode.add_argument("--refresh", action="store_true", help="atomically refresh generated outputs")
    parser.add_argument("--library-name", default="compiler-rt")
    progress = parser.add_mutually_exclusive_group()
    progress.add_argument("--checkpoint", type=Path, help="create a new resumable checkpoint")
    progress.add_argument("--resume", type=Path, help="resume from an existing checkpoint")
    parser.add_argument("--stop-after-members", type=int, help=argparse.SUPPRESS)
    parser.add_argument(
        "--cross-check-apple-tools",
        action="store_true",
        help="require lipo/nm/otool/llvm-objdump structural counts to agree",
    )
    parser.add_argument(
        "--swift-output",
        type=Path,
        default=repository_root / "MacScope/Services/FunctionSignatures/FunctionSignatureCorpus.swift",
    )
    parser.add_argument(
        "--oracle-fixture-output",
        type=Path,
        default=repository_root / "Scripts/function-signatures/compiler_rt_source_fixtures.json",
    )
    parser.add_argument(
        "--manifest-output",
        type=Path,
        default=repository_root / "Scripts/function-signatures/compiler_rt_signatures_manifest.json",
    )
    parser.add_argument(
        "--rejections-output",
        type=Path,
        default=repository_root / "Scripts/function-signatures/compiler_rt_signature_rejections.json",
    )
    return parser


def main(argv: list[str] | None = None) -> int:
    arguments = _argument_parser().parse_args(argv)
    checkpoint_path = arguments.checkpoint or arguments.resume
    outputs = {
        "swift_source": arguments.swift_output,
        "oracle_fixture_json": arguments.oracle_fixture_output,
        "manifest_json": arguments.manifest_output,
        "rejections_json": arguments.rejections_output,
    }
    if arguments.refresh:
        try:
            _validate_refresh_paths(
                outputs,
                archive=arguments.archive,
                checkpoint_path=checkpoint_path,
            )
        except ParseError as error:
            print(f"error: {error}")
            return 2
    if arguments.checkpoint is not None and arguments.checkpoint.exists():
        print("error: --checkpoint path already exists; use --resume")
        return 2
    if arguments.resume is not None and not arguments.resume.exists():
        print("error: --resume checkpoint does not exist")
        return 2
    if arguments.stop_after_members is not None and checkpoint_path is None:
        print("error: --stop-after-members requires --checkpoint or --resume")
        return 2
    try:
        source = arguments.archive.read_bytes()
    except OSError as error:
        print(f"error: cannot read archive: {error}")
        return 2
    actual_sha256 = hashlib.sha256(source).hexdigest()
    if actual_sha256 != arguments.expected_sha256.lower():
        print(
            "error: archive SHA-256 drift: "
            f"expected {arguments.expected_sha256.lower()}, got {actual_sha256}"
        )
        return 2
    try:
        first = generate_artifacts(
            source,
            library_name=arguments.library_name,
            checkpoint_path=checkpoint_path,
            stop_after_members=arguments.stop_after_members,
        )
        second = generate_artifacts(source, library_name=arguments.library_name)
    except CheckpointStop as stop:
        print(str(stop))
        return 75
    except ParseError as error:
        print(f"error: {error}")
        return 2
    if first != second:
        print("error: two in-memory generations were not byte-identical")
        return 2
    try:
        verify_dual_temporary_render(first)
        if arguments.cross_check_apple_tools:
            evidence = cross_check_apple_tools(arguments.archive)
            manifest = json.loads(first.manifest_json)
            expected_evidence = {
                "arm64_offset": manifest["selected_cpu"]["slice_offset"],
                "arm64_size": manifest["selected_cpu"]["slice_size"],
                "archive_members": manifest["counts"]["archive_members"],
                "boundary_symbols": manifest["counts"]["boundary_symbols"],
                "text_relocation_records": manifest["counts"]["text_relocation_records"],
            }
            if evidence != expected_evidence:
                raise ParseError(
                    f"Apple-tool evidence disagrees: parser={expected_evidence}, tools={evidence}"
                )
    except ParseError as error:
        print(f"error: {error}")
        return 2
    drift = synchronize_artifacts(first, outputs, refresh=arguments.refresh)
    if drift:
        for path in drift:
            print(f"drift: {path}")
        return 1
    action = "refreshed" if arguments.refresh else "verified"
    print(f"{action} {len(outputs)} deterministic artifacts")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
