#!/usr/bin/env python3
"""Deterministic, repository-owned Mach-O and PE parser specimens (RX-03).

Every specimen is synthesized byte-for-byte from this file, so its identity is
reproducible and owned by MacScope. Specimens are inert parser inputs: they are
written without execute permission and are never run, mapped or loaded.

    specimens.py --write   regenerate Scripts/parser-oracles/specimens/*.bin
    specimens.py --check   prove the committed bytes equal the generator output

Standard library only; Python 3.9 compatible.
"""

from __future__ import annotations

import argparse
import struct
import sys
from pathlib import Path
from typing import Callable, Dict, List, Optional, Tuple

SPECIMEN_DIR = Path(__file__).resolve().parent / "specimens"

# Mach-O constants (mach-o/loader.h, mach/machine.h)
MH_MAGIC_64 = 0xFEEDFACF
FAT_MAGIC = 0xCAFEBABE
CPU_TYPE_ARM64 = 0x0100000C
CPU_TYPE_X86_64 = 0x01000007
CPU_SUBTYPE_ARM64_ALL = 0
CPU_SUBTYPE_ARM64E = 2
CPU_SUBTYPE_PTRAUTH_ABI = 0x80000000
CPU_SUBTYPE_X86_64_ALL = 3
MH_EXECUTE = 2
MH_DYLIB = 6
MH_NOUNDEFS, MH_DYLDLINK, MH_TWOLEVEL, MH_PIE, MH_NO_REEXPORTED_DYLIBS = 0x1, 0x4, 0x80, 0x200000, 0x100000
LC_SEGMENT_64 = 0x19
LC_SYMTAB = 0x2
LC_DYSYMTAB = 0xB
LC_LOAD_DYLIB = 0xC
LC_ID_DYLIB = 0xD
LC_LOAD_DYLINKER = 0xE
LC_UUID = 0x1B
LC_BUILD_VERSION = 0x32
LC_MAIN = 0x80000028
N_SECT, N_EXT = 0xE, 0x1
S_ATTR_CODE = 0x80000400  # S_ATTR_PURE_INSTRUCTIONS | S_ATTR_SOME_INSTRUCTIONS
VM_R, VM_X = 1, 4
TEXT_VMADDR = 0x100000000
PAGE = 0x4000

ARM64_CODE = struct.pack("<II", 0x52800000, 0xD65F03C0)  # mov w0, #0 ; ret
X86_64_CODE = bytes([0x31, 0xC0, 0xC3, 0x90])  # xor eax, eax ; ret ; nop


def _pad(payload: bytes, alignment: int) -> bytes:
    return payload + b"\x00" * (-len(payload) % alignment)


def _dylib_command(cmd: int, name: str, current: int, compatibility: int) -> bytes:
    name_bytes = _pad(name.encode("ascii") + b"\x00", 8)
    size = 24 + len(name_bytes)
    return struct.pack("<IIIIII", cmd, size, 24, 2, current, compatibility) + name_bytes


def _dylinker_command(name: str) -> bytes:
    raw = name.encode("ascii") + b"\x00"
    size = 12 + len(raw)
    size += -size % 8
    return struct.pack("<III", LC_LOAD_DYLINKER, size, 12) + raw + b"\x00" * (size - 12 - len(raw))


def _segment(name: str, vmaddr: int, vmsize: int, fileoff: int, filesize: int,
             maxprot: int, initprot: int, sections: List[Tuple[str, int, int, int, int]]) -> bytes:
    payload = struct.pack(
        "<II16sQQQQIIII", LC_SEGMENT_64, 72 + 80 * len(sections), name.encode("ascii"),
        vmaddr, vmsize, fileoff, filesize, maxprot, initprot, len(sections), 0,
    )
    for sectname, addr, size, offset, flags in sections:
        payload += struct.pack(
            "<16s16sQQIIIIIIII", sectname.encode("ascii"), name.encode("ascii"),
            addr, size, offset, 4, 0, 0, flags, 0, 0, 0,
        )
    return payload


def thin_macho(*, cputype: int, cpusubtype: int, filetype: int, uuid: bytes,
               code: bytes, symbol: str, install_name: str = "",
               sizeofcmds_override: int = 0) -> bytes:
    """One small, structurally complete 64-bit Mach-O image.

    Layout: header + load commands, then __TEXT,__text at TEXT_OFFSET, then the
    __LINKEDIT symbol and string tables. Offsets are compact (not page aligned)
    to keep specimens small; vm sizes are page granular as dyld expects.
    """
    text_offset = 0x400
    linkedit_offset = 0x800
    is_exec = filetype == MH_EXECUTE
    strtab = b"\x00" + (b"__mh_execute_header\x00" if is_exec else b"") + symbol.encode("ascii") + b"\x00"
    strtab = _pad(strtab, 8)
    text_addr = TEXT_VMADDR + text_offset if is_exec else text_offset
    symbols = []
    if is_exec:
        symbols.append(struct.pack("<IBBHQ", 1, N_SECT | N_EXT, 1, 0x10, TEXT_VMADDR))
        symbols.append(struct.pack("<IBBHQ", 1 + len("__mh_execute_header") + 1, N_SECT | N_EXT, 1, 0, text_addr))
    else:
        symbols.append(struct.pack("<IBBHQ", 1, N_SECT | N_EXT, 1, 0, text_addr))
    symtab = b"".join(symbols)
    linkedit = symtab + strtab
    text_base = TEXT_VMADDR if is_exec else 0
    commands: List[bytes] = []
    if is_exec:
        commands.append(_segment("__PAGEZERO", 0, TEXT_VMADDR, 0, 0, 0, 0, []))
    commands.append(_segment("__TEXT", text_base, PAGE, 0, text_offset + len(code), VM_R | VM_X, VM_R | VM_X,
                             [("__text", text_addr, len(code), text_offset, S_ATTR_CODE)]))
    commands.append(_segment("__LINKEDIT", text_base + PAGE, PAGE, linkedit_offset, len(linkedit), VM_R, VM_R, []))
    if not is_exec:
        commands.append(_dylib_command(LC_ID_DYLIB, install_name, 0x00010000, 0x00010000))
    commands.append(struct.pack("<IIIIII", LC_SYMTAB, 24, linkedit_offset, len(symbols),
                                linkedit_offset + len(symtab), len(strtab)))
    commands.append(struct.pack("<II18I", LC_DYSYMTAB, 80, 0, 0, 0, len(symbols), len(symbols), 0, *([0] * 12)))
    if is_exec:
        commands.append(_dylinker_command("/usr/lib/dyld"))
    commands.append(struct.pack("<II", LC_UUID, 24) + uuid)
    commands.append(struct.pack("<IIIIII", LC_BUILD_VERSION, 24, 1, 0x000E0000, 0x000F0000, 0))
    if is_exec:
        commands.append(struct.pack("<IIQQ", LC_MAIN, 24, text_offset, 0))
    commands.append(_dylib_command(LC_LOAD_DYLIB, "/usr/lib/libSystem.B.dylib", 0x05276403, 0x00010000))
    load_commands = b"".join(commands)
    flags = MH_NOUNDEFS | MH_DYLDLINK | MH_TWOLEVEL | (MH_PIE if is_exec else MH_NO_REEXPORTED_DYLIBS)
    sizeofcmds = sizeofcmds_override or len(load_commands)
    header = struct.pack("<IIIIIIII", MH_MAGIC_64, cputype, cpusubtype, filetype, len(commands),
                         sizeofcmds, flags, 0)
    image = header + load_commands
    if len(image) > text_offset:
        raise ValueError("load commands overflow the text offset")
    image = image + b"\x00" * (text_offset - len(image)) + code
    image = image + b"\x00" * (linkedit_offset - len(image)) + linkedit
    return image


def fat_macho(slices: List[Tuple[int, int, bytes]], align_log2: int = 12) -> bytes:
    alignment = 1 << align_log2
    header = struct.pack(">II", FAT_MAGIC, len(slices))
    offset = alignment
    arch_records = b""
    body = b""
    for cputype, cpusubtype, image in slices:
        arch_records += struct.pack(">IIIII", cputype, cpusubtype, offset, len(image), align_log2)
        body += image + b"\x00" * (-len(image) % alignment)
        offset += len(image) + (-len(image) % alignment)
    prefix = header + arch_records
    return prefix + b"\x00" * (alignment - len(prefix)) + body


UUID_EXEC = bytes.fromhex("6d5c1f0e2a4b4c8d9e0f112233445566")
UUID_DYLIB = bytes.fromhex("0a1b2c3d4e5f40718293a4b5c6d7e8f9")
UUID_X86 = bytes.fromhex("11223344556647788899aabbccddeeff")


def macho_thin_arm64_exec() -> bytes:
    return thin_macho(cputype=CPU_TYPE_ARM64, cpusubtype=CPU_SUBTYPE_ARM64_ALL, filetype=MH_EXECUTE,
                      uuid=UUID_EXEC, code=ARM64_CODE, symbol="_main")


def macho_thin_arm64_exec_replaced() -> bytes:
    """Same LC_UUID as the original, one instruction changed: identity must be bytes, not UUID."""
    return thin_macho(cputype=CPU_TYPE_ARM64, cpusubtype=CPU_SUBTYPE_ARM64_ALL, filetype=MH_EXECUTE,
                      uuid=UUID_EXEC, code=struct.pack("<II", 0x52800020, 0xD65F03C0), symbol="_main")


def macho_arm64e_dylib() -> bytes:
    return thin_macho(cputype=CPU_TYPE_ARM64, cpusubtype=CPU_SUBTYPE_ARM64E | CPU_SUBTYPE_PTRAUTH_ABI,
                      filetype=MH_DYLIB, uuid=UUID_DYLIB, code=ARM64_CODE, symbol="_oracle_fixture_function",
                      install_name="@rpath/libOracleFixture.dylib")


def macho_fat_x86_64_arm64() -> bytes:
    x86 = thin_macho(cputype=CPU_TYPE_X86_64, cpusubtype=CPU_SUBTYPE_X86_64_ALL, filetype=MH_EXECUTE,
                     uuid=UUID_X86, code=X86_64_CODE, symbol="_main")
    return fat_macho([
        (CPU_TYPE_X86_64, CPU_SUBTYPE_X86_64_ALL, x86),
        (CPU_TYPE_ARM64, CPU_SUBTYPE_ARM64_ALL, macho_thin_arm64_exec()),
    ])


def macho_sizeofcmds_overflow() -> bytes:
    """Negative case: sizeofcmds claims more bytes than the file holds."""
    return thin_macho(cputype=CPU_TYPE_ARM64, cpusubtype=CPU_SUBTYPE_ARM64_ALL, filetype=MH_EXECUTE,
                      uuid=UUID_EXEC, code=ARM64_CODE, symbol="_main", sizeofcmds_override=0x100000)


# PE constants (winnt.h / PE/COFF specification)
IMAGE_FILE_MACHINE_AMD64 = 0x8664
SCN_CODE = 0x60000020   # CNT_CODE | MEM_EXECUTE | MEM_READ
SCN_RDATA = 0x40000040  # CNT_INITIALIZED_DATA | MEM_READ
SCN_DATA = 0xC0000040   # CNT_INITIALIZED_DATA | MEM_READ | MEM_WRITE
FILE_ALIGN = 0x200
SECTION_ALIGN = 0x1000
PE_IMAGE_BASE = 0x140000000


def _pe_image(sections: List[Tuple[bytes, bytes, int]], import_rva: int, import_size: int,
              string_table: bytes = b"") -> bytes:
    """PE32+ image: DOS header, PE header, optional header, section table, raw data.

    `sections` entries are (8-byte name field, raw bytes, characteristics);
    section i is placed at RVA 0x1000 * (i + 1) and file offset 0x200 * (i + 1)
    (each raw section is at most one file-alignment unit unless larger).
    """
    raw_offsets = []
    raw_pointer = FILE_ALIGN
    for _, raw, _ in sections:
        raw_offsets.append(raw_pointer)
        raw_pointer += len(raw) + (-len(raw) % FILE_ALIGN)
    symbol_table_pointer = raw_pointer if string_table else 0
    dos = bytearray(0x40)
    dos[0:2] = b"MZ"
    struct.pack_into("<I", dos, 0x3C, 0x40)
    coff = struct.pack("<4sHHIIIHH", b"PE\x00\x00", IMAGE_FILE_MACHINE_AMD64, len(sections), 0,
                       symbol_table_pointer, 0, 0xF0, 0x0022)
    size_of_image = SECTION_ALIGN
    for index, (_, raw, _) in enumerate(sections):
        end = SECTION_ALIGN * (index + 1) + max(len(raw), 1)
        size_of_image = max(size_of_image, end + (-end % SECTION_ALIGN))
    optional = struct.pack(
        "<HBBIIIIIQIIHHHHHHIIIIHHQQQQII",
        0x20B, 14, 0, len(sections[0][1]), 0, 0, SECTION_ALIGN, SECTION_ALIGN, PE_IMAGE_BASE,
        SECTION_ALIGN, FILE_ALIGN, 6, 0, 0, 0, 6, 0, 0, size_of_image, FILE_ALIGN, 0, 3, 0x8160,
        0x100000, 0x1000, 0x100000, 0x1000, 0, 16,
    )
    directories = [(0, 0)] * 16
    directories[1] = (import_rva, import_size)
    optional += b"".join(struct.pack("<II", rva, size) for rva, size in directories)
    section_table = b""
    for index, (name, raw, characteristics) in enumerate(sections):
        section_table += struct.pack("<8sIIIIIIHHI", name, max(len(raw), 1), SECTION_ALIGN * (index + 1),
                                     len(raw) + (-len(raw) % FILE_ALIGN), raw_offsets[index], 0, 0, 0, 0,
                                     characteristics)
    headers = bytes(dos) + coff + optional + section_table
    if len(headers) > FILE_ALIGN:
        raise ValueError("PE headers overflow the first file-alignment unit")
    image = headers + b"\x00" * (FILE_ALIGN - len(headers))
    for raw in (raw for _, raw, _ in sections):
        image += raw + b"\x00" * (-len(raw) % FILE_ALIGN)
    if string_table:
        image += struct.pack("<I", 4 + len(string_table)) + string_table
    return image


def _import_section(rva: int, modules: List[Tuple[str, List[str]]],
                    shared_name: Optional[Tuple[int, str]] = None) -> Tuple[bytes, int, int]:
    """Build .rdata holding import descriptors, ILT/IAT thunks, DLL names and hint/name entries."""
    descriptor_size = 20 * (len(modules) + 1)
    cursor = descriptor_size
    layouts = []
    for _, functions in modules:
        count = len(functions) if shared_name is None else shared_name[0]
        ilt = cursor
        cursor += 8 * (count + 1)
        iat = cursor
        cursor += 8 * (count + 1)
        layouts.append((ilt, iat, count))
    names = b""
    name_offsets: Dict[str, int] = {}
    hint_offsets: Dict[str, int] = {}
    for module, functions in modules:
        name_offsets[module] = cursor + len(names)
        names += _pad(module.encode("ascii") + b"\x00", 2)
        unique = [shared_name[1]] if shared_name else functions
        for function in unique:
            hint_offsets[function] = cursor + len(names)
            names += _pad(struct.pack("<H", 0) + function.encode("ascii") + b"\x00", 2)
    payload = bytearray(cursor + len(names))
    payload[cursor:] = names
    for index, (module, functions) in enumerate(modules):
        ilt, iat, count = layouts[index]
        struct.pack_into("<IIIII", payload, 20 * index, rva + ilt, 0, 0, rva + name_offsets[module], rva + iat)
        for slot in range(count):
            function = shared_name[1] if shared_name else functions[slot]
            target = rva + hint_offsets[function]
            struct.pack_into("<Q", payload, ilt + 8 * slot, target)
            struct.pack_into("<Q", payload, iat + 8 * slot, target)
    return bytes(payload), rva, descriptor_size


def pe_pe32plus_imports() -> bytes:
    rdata, import_rva, import_size = _import_section(0x2000, [
        ("KERNEL32.dll", ["ExitProcess", "GetStdHandle"]),
        ("USER32.dll", ["MessageBoxA"]),
    ])
    return _pe_image([
        (b".text\x00\x00\x00", bytes([0x31, 0xC0, 0xC3]), SCN_CODE),
        (b".rdata\x00\x00", rdata, SCN_RDATA),
        (b".data\x00\x00\x00", b"MacScope parser oracle\x00", SCN_DATA),
    ], import_rva, import_size)


def pe_long_section_name() -> bytes:
    """A '/4' section name resolved through the COFF string table (images normally avoid this)."""
    rdata, import_rva, import_size = _import_section(0x2000, [("KERNEL32.dll", ["ExitProcess"])])
    return _pe_image([
        (b".text\x00\x00\x00", bytes([0x31, 0xC0, 0xC3]), SCN_CODE),
        (b".rdata\x00\x00", rdata, SCN_RDATA),
        (b"/4\x00\x00\x00\x00\x00\x00", b"long-name section payload\x00", SCN_DATA),
    ], import_rva, import_size, string_table=b".oracle_long_section_name\x00")


AMPLIFICATION_THUNKS = 64
AMPLIFICATION_NAME_BYTES = 4096


def pe_import_name_amplification() -> bytes:
    """Scaled-down MS-14 shape: many thunks share one long hint/name entry."""
    name = "A" * AMPLIFICATION_NAME_BYTES
    rdata, import_rva, import_size = _import_section(
        0x2000, [("lib.dll", [name])], shared_name=(AMPLIFICATION_THUNKS, name))
    return _pe_image([
        (b".text\x00\x00\x00", bytes([0x31, 0xC0, 0xC3]), SCN_CODE),
        (b".idata\x00\x00", rdata, SCN_RDATA),
    ], import_rva, import_size)


GENERATORS: Dict[str, Callable[[], bytes]] = {
    "macho-thin-arm64-exec.bin": macho_thin_arm64_exec,
    "macho-thin-arm64-exec-replaced.bin": macho_thin_arm64_exec_replaced,
    "macho-arm64e-dylib.bin": macho_arm64e_dylib,
    "macho-fat-x86_64-arm64.bin": macho_fat_x86_64_arm64,
    "macho-sizeofcmds-overflow.bin": macho_sizeofcmds_overflow,
    "pe-pe32plus-imports.bin": pe_pe32plus_imports,
    "pe-long-section-name.bin": pe_long_section_name,
    "pe-import-name-amplification.bin": pe_import_name_amplification,
}


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--write", action="store_true")
    mode.add_argument("--check", action="store_true")
    args = parser.parse_args(argv)
    mismatches = []
    for name, generator in sorted(GENERATORS.items()):
        payload = generator()
        path = SPECIMEN_DIR / name
        if args.write:
            SPECIMEN_DIR.mkdir(parents=True, exist_ok=True)
            path.write_bytes(payload)
            path.chmod(0o644)
        elif not path.is_file() or path.read_bytes() != payload:
            mismatches.append(name)
    if mismatches:
        print("specimen bytes differ from the generator: " + ", ".join(mismatches), file=sys.stderr)
        return 1
    print(f"{len(GENERATORS)} specimen(s) {'written' if args.write else 'verified'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
