#!/usr/bin/env python3
"""Normalize untrusted oracle output into MacScope-owned parser facts (RX-03).

The linked engines (LIEF, go-macho, pe-parse) emit one shared raw schema of
numbers from the MacScope bridge; Apple dyld_info emits text. These pure
functions map both onto one closed MacScope schema so facts can be compared across oracles and frozen as
goldens. Tool output is untrusted: values are type-checked, strings are bounded
and nothing is evaluated. Standard library only; Python 3.9 compatible.
"""

from __future__ import annotations

import hashlib
import re
from typing import Any, Dict, Iterable, List, Optional

MAX_FACT_STRING = 256

CPU_NAMES = {0x0100000C: "arm64", 0x01000007: "x86_64", 0x0C: "arm", 0x07: "i386"}
FILETYPES = {1: "object", 2: "execute", 6: "dylib", 7: "dylinker", 8: "bundle", 11: "kext_bundle", 12: "fileset"}
MH_FLAGS = [
    (0x1, "noundefs"), (0x2, "incrlink"), (0x4, "dyldlink"), (0x8, "bindatload"), (0x10, "prebound"),
    (0x20, "split_segs"), (0x80, "twolevel"), (0x100, "force_flat"), (0x200, "nomultidefs"),
    (0x8000, "weak_defines"), (0x10000, "binds_to_weak"), (0x20000, "allow_stack_execution"),
    (0x40000, "root_safe"), (0x80000, "setuid_safe"), (0x100000, "no_reexported_dylibs"),
    (0x200000, "pie"), (0x400000, "dead_strippable_dylib"), (0x800000, "has_tlv_descriptors"),
    (0x1000000, "no_heap_execution"), (0x2000000, "app_extension_safe"),
    (0x80000000, "dylib_in_cache"),
]
LOAD_COMMANDS = {
    0x1: "LC_SEGMENT", 0x2: "LC_SYMTAB", 0xB: "LC_DYSYMTAB", 0xC: "LC_LOAD_DYLIB", 0xD: "LC_ID_DYLIB",
    0xE: "LC_LOAD_DYLINKER", 0x19: "LC_SEGMENT_64", 0x1B: "LC_UUID", 0x1D: "LC_CODE_SIGNATURE",
    0x26: "LC_FUNCTION_STARTS", 0x29: "LC_DATA_IN_CODE", 0x2A: "LC_SOURCE_VERSION", 0x32: "LC_BUILD_VERSION",
    0x80000018: "LC_LOAD_WEAK_DYLIB", 0x8000001F: "LC_REEXPORT_DYLIB", 0x80000028: "LC_MAIN",
    0x80000033: "LC_DYLD_EXPORTS_TRIE", 0x80000034: "LC_DYLD_CHAINED_FIXUPS",
}
DYLIB_REFERENCE_COMMANDS = {0xC, 0x80000018, 0x8000001F}
PLATFORMS = {1: "macos", 2: "ios", 3: "tvos", 4: "watchos", 6: "maccatalyst", 7: "iossimulator", 11: "visionos"}
PE_MACHINES = {0x14C: "i386", 0x8664: "amd64", 0xAA64: "arm64", 0x1C0: "arm"}
PE_MAGIC = {0x10B: "pe32", 0x20B: "pe32+"}


class NormalizationError(ValueError):
    pass


def bounded(value: Any) -> str:
    """A tool string, or a stable digest stand-in when it exceeds the fact bound."""
    if not isinstance(value, str):
        raise NormalizationError(f"expected a string, found {type(value).__name__}")
    if len(value) <= MAX_FACT_STRING:
        return value
    digest = hashlib.sha256(value.encode("utf-8", "surrogatepass")).hexdigest()
    return f"<bounded length={len(value)} sha256={digest}>"


def integer(value: Any) -> int:
    if isinstance(value, bool) or not isinstance(value, int):
        raise NormalizationError(f"expected an integer, found {value!r}")
    return value


def arch_name(cputype: int, cpusubtype: int) -> str:
    base = cpusubtype & 0x00FFFFFF
    if cputype == 0x0100000C:
        return "arm64e" if base == 2 else ("arm64" if base in (0, 1) else f"arm64:{base}")
    if cputype == 0x01000007:
        return "x86_64" if base in (3, 8) else f"x86_64:{base}"
    return CPU_NAMES.get(cputype, f"cpu:{cputype:#x}") + f":{base}"


def ptrauth_abi(cputype: int, cpusubtype: int) -> bool:
    return cputype == 0x0100000C and bool(cpusubtype & 0x80000000)


def flag_names(flags: int) -> List[str]:
    names = [name for bit, name in MH_FLAGS if flags & bit]
    known = 0
    for bit, _ in MH_FLAGS:
        known |= bit
    if flags & ~known:
        names.append(f"unknown:{flags & ~known:#x}")
    return sorted(names)


def protection(value: int) -> str:
    return ("r" if value & 1 else "-") + ("w" if value & 2 else "-") + ("x" if value & 4 else "-")


def version_text(parts: Iterable[int]) -> str:
    values = [int(part) for part in parts][:3]
    while len(values) < 3:
        values.append(0)
    return ".".join(str(part) for part in values)


def dotted_version(text: str) -> str:
    if not isinstance(text, str) or not re.fullmatch(r"\d+(\.\d+){0,4}", text):
        raise NormalizationError(f"unexpected version text: {text!r}")
    return version_text(int(part) for part in text.split("."))


def uuid_text(raw: str) -> str:
    compact = raw.replace("-", "").lower()
    if not re.fullmatch(r"[0-9a-f]{32}", compact):
        raise NormalizationError(f"unexpected UUID: {raw!r}")
    upper = compact.upper()
    return f"{upper[:8]}-{upper[8:12]}-{upper[12:16]}-{upper[16:20]}-{upper[20:]}"


# --- Mach-O --------------------------------------------------------------

def _macho_facts(*, arch: str, ptrauth: bool, filetype: str, ncmds: int, sizeofcmds: int,
                 flags: List[str], load_commands: List[str], segments: List[Dict[str, Any]],
                 sections: List[Dict[str, Any]], uuid: Optional[str], dylibs: List[str],
                 id_dylib: Optional[str], entry_offset: Optional[int],
                 build_version: Optional[Dict[str, str]]) -> Dict[str, Any]:
    return {
        "arch": arch, "ptrauth_abi": ptrauth, "filetype": filetype, "ncmds": ncmds,
        "sizeofcmds": sizeofcmds, "flags": flags, "load_commands": load_commands,
        "segments": segments, "sections": sections, "uuid": uuid, "dylibs": dylibs,
        "id_dylib": id_dylib, "entry_offset": entry_offset, "build_version": build_version,
    }


def normalize_raw_macho_slice(raw: Dict[str, Any]) -> Dict[str, Any]:
    cputype = integer(raw["cputype"])
    cpusubtype = integer(raw["cpusubtype"])
    commands = [integer(command) for command in raw["commands"]]
    segments, sections = [], []
    for segment in raw["segments"]:
        segments.append({
            "name": bounded(segment["name"]), "vmaddr": integer(segment["vmaddr"]),
            "vmsize": integer(segment["vmsize"]), "fileoff": integer(segment["fileoff"]),
            "filesize": integer(segment["filesize"]), "maxprot": protection(integer(segment["maxprot"])),
            "initprot": protection(integer(segment["initprot"])),
        })
        for section in segment["sections"]:
            sections.append({
                "segment": bounded(section["segment"]), "name": bounded(section["name"]),
                "addr": integer(section["addr"]), "size": integer(section["size"]),
                "offset": integer(section["offset"]),
            })
    build = raw.get("build_version")
    id_dylib = raw.get("id_dylib")
    dylibs = [bounded(name) for name in raw["dylibs"]]
    facts = _macho_facts(
        arch=arch_name(cputype, cpusubtype), ptrauth=ptrauth_abi(cputype, cpusubtype),
        filetype=FILETYPES.get(integer(raw["filetype"]), f"filetype:{raw['filetype']}"),
        ncmds=integer(raw["ncmds"]), sizeofcmds=integer(raw["sizeofcmds"]),
        flags=flag_names(integer(raw["flags"])),
        load_commands=[LOAD_COMMANDS.get(command, f"LC_{command:#x}") for command in commands],
        segments=segments, sections=sections,
        uuid=uuid_text(raw["uuid"]) if raw.get("uuid") else None,
        dylibs=dylibs, id_dylib=bounded(id_dylib) if id_dylib else None,
        entry_offset=integer(raw["entry_offset"]) if raw.get("entry_offset") is not None else None,
        build_version=None if build is None else {
            "platform": PLATFORMS.get(integer(build["platform"]), f"platform:{build['platform']}"),
            "minos": version_text(build["minos"]), "sdk": version_text(build["sdk"]),
        },
    )
    facts["fat_offset"] = integer(raw.get("fat_offset", 0))
    return facts


# --- PE ------------------------------------------------------------------

def normalize_pe(raw: Dict[str, Any]) -> Dict[str, Any]:
    """Shared by the LIEF and pe-parse adapters, which emit the same raw field names.

    DLL names are case-insensitive on Windows and pe-parse upper-cases them, so
    module names are compared lower-cased. Section names are the raw 8-byte
    field; '/n' string-table references are not resolved by either oracle.
    """
    imports = [{"module": bounded(item["module"]).lower(), "function": bounded(item["function"])}
               for item in raw["imports"]]
    exports = sorted(
        ({"name": bounded(item["name"]), "ordinal": integer(item["ordinal"])} for item in raw["exports"]),
        key=lambda item: (item["ordinal"], item["name"]),
    )
    entry = raw.get("entry_point_va")
    return {
        "machine": PE_MACHINES.get(integer(raw["machine"]), f"machine:{raw['machine']:#x}"),
        "format": PE_MAGIC.get(integer(raw["optional_magic"]), f"magic:{raw['optional_magic']:#x}"),
        "number_of_sections": integer(raw["number_of_sections"]),
        "image_base": integer(raw["image_base"]),
        "entry_point_va": None if entry is None else integer(entry),
        "sections": [{
            "name": bounded(section["name"]), "va": integer(section["va"]),
            "virtual_size": integer(section["virtual_size"]), "raw_pointer": integer(section["raw_pointer"]),
            "raw_size": integer(section["raw_size"]), "characteristics": integer(section["characteristics"]),
        } for section in raw["sections"]],
        "import_count": len(imports),
        "imports": imports,
        "exports": exports,
    }


# --- dyld shared cache ---------------------------------------------------

_DYLD_INFO_SEGMENT = re.compile(r"^\s+0x([0-9A-Fa-f]+)\s+(\S+)\s+(\d+)KB\s+([r.][w.][x.])/([r.][w.][x.])\s*$")
_DYLD_INFO_SECTION = re.compile(r"^\s+0x([0-9A-Fa-f]+)\s+(\S+)\s+(\d+)\s*$")


def normalize_dyld_info(text: str) -> Dict[str, Any]:
    """Apple `dyld_info -platform -segments -dependents <image>` text output (platform tool).

    The dependents block is headed `-linked_dylibs:`; attribute words (weak-link,
    lazy-load, upward) precede the path and are dropped.
    """
    if not isinstance(text, str):
        raise NormalizationError("dyld_info output must be text")
    mode = None
    segments: List[Dict[str, Any]] = []
    sections: List[Dict[str, Any]] = []
    dependents: List[str] = []
    platform = None
    current_segment = None
    for line in text.splitlines():
        stripped = line.strip()
        if stripped in ("-platform:", "-segments:", "-linked_dylibs:"):
            mode = stripped[1:-1]
            continue
        if not stripped or stripped.startswith(("platform ", "unslid-addr", "attributes ")):
            continue
        if mode == "platform" and platform is None:
            fields = stripped.split()
            platform = {"platform": fields[0], "minos": dotted_version(fields[-2]), "sdk": dotted_version(fields[-1])}
        elif mode == "segments":
            segment = _DYLD_INFO_SEGMENT.match(line)
            section = _DYLD_INFO_SECTION.match(line)
            if segment:
                current_segment = segment.group(2)
                segments.append({
                    "name": bounded(current_segment), "vmaddr": int(segment.group(1), 16),
                    "size_kb": int(segment.group(3)),
                    "initprot": segment.group(4).replace(".", "-"), "maxprot": segment.group(5).replace(".", "-"),
                })
            elif section and current_segment is not None:
                sections.append({"segment": current_segment, "name": bounded(section.group(2)),
                                 "addr": int(section.group(1), 16), "size": int(section.group(3))})
        elif mode == "linked_dylibs":
            fields = stripped.split()
            dependents.append(bounded(fields[-1]))
    return {"platform": platform, "segments": segments, "sections": sections, "dependents": dependents}
