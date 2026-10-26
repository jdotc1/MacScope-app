#!/usr/bin/env python3
"""Per-function equivalence tiers between two arm64 Mach-O builds.

usage: python3 -I tiers.py A.bin A.nm B.bin B.nm out.json [label] [options]

Tiers per paired function (paired by symbol name present on both sides):
  exact       : identical machine-code bytes and identical content of every
                resolvable referenced constant (reason "constant" otherwise)
  normalised  : bytes differ, but the instruction streams are equal after masking
                adrp pages and their lo12 offsets, PC-relative literal loads, adr,
                bl targets, tail-call/out-of-function branch targets (EXT), and
                in-function branch targets rewritten as relative offsets
  different   : instruction streams differ after masking (sizes may differ), or the
                bytes are identical but a referenced constant differs; every different
                function carries a reason: constant, incomplete-stream,
                restored-page-base, unverified-constant, path-length or instruction
"""
import argparse
import bisect
import collections
import hashlib
import json
import re
import struct
import subprocess
import sys
import time

OBJDUMP = "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/llvm-objdump"
LC_SEGMENT_64 = 0x19

class InputError(ValueError):
    """An input cannot be analysed safely."""


def macho_sections(path):
    """Read file-backed sections and segments of a thin arm64 Mach-O."""
    with open(path, "rb") as f:
        data = f.read()
    if len(data) < 32:
        raise InputError(f"{path}: truncated Mach-O header")
    magic, = struct.unpack_from("<I", data, 0)
    if magic != 0xfeedfacf:
        raise InputError(f"{path}: not a thin 64-bit Mach-O (magic {magic:#x})")
    cputype, = struct.unpack_from("<I", data, 4)
    if cputype != 0x0100000c:
        raise InputError(f"{path}: not arm64 (CPU type {cputype:#x})")
    ncmds, sizeofcmds = struct.unpack_from("<II", data, 16)
    command_end = 32 + sizeofcmds
    if command_end > len(data):
        raise InputError(f"{path}: truncated load commands")
    off = 32
    sections, segments = {}, {}
    def name(raw):
        return raw.rstrip(b"\0").decode("utf-8", errors="replace")
    def content(offset, size):
        if offset > len(data) or size > len(data) - offset:
            raise InputError(f"{path}: file range outside input")
        return data[offset:offset + size]
    for _ in range(ncmds):
        if off + 8 > command_end:
            raise InputError(f"{path}: truncated load command")
        cmd, cmdsize = struct.unpack_from("<II", data, off)
        if cmdsize < 8 or off + cmdsize > command_end:
            raise InputError(f"{path}: invalid load command size")
        if cmd == LC_SEGMENT_64:
            if cmdsize < 72:
                raise InputError(f"{path}: truncated segment command")
            segname = name(data[off+8:off+24])
            vmaddr, vmsize, fileoff, filesize = struct.unpack_from("<QQQQ", data, off+24)
            if segname in segments:
                raise InputError(f"{path}: duplicate segment {segname}")
            segments[segname] = dict(addr=vmaddr, size=vmsize, data=content(fileoff, filesize))
            nsects, = struct.unpack_from("<I", data, off+64)
            if 72 + 80 * nsects > cmdsize:
                raise InputError(f"{path}: truncated section table")
            soff = off + 72
            for _ in range(nsects):
                sectname = name(data[soff:soff+16])
                addr, size, fileoff = struct.unpack_from("<QQI", data, soff+32)
                flags, = struct.unpack_from("<I", data, soff+64)
                zero_fill = (flags & 0xff) in (1, 0xc, 0x12)
                key = (segname, sectname)
                if key in sections:
                    raise InputError(f"{path}: duplicate section {key}")
                sections[key] = dict(addr=addr, size=size, zero_fill=zero_fill,
                                     data=b"" if zero_fill else content(fileoff, size),
                                     constant_window=b"" if zero_fill else data[fileoff:min(len(data), fileoff+size+15)])
                soff += 80
        off += cmdsize
    if ("__TEXT", "__text") not in sections:
        raise InputError(f"{path}: no __TEXT,__text")
    return sections, segments


def text_section(path):
    sections, _ = macho_sections(path)
    text = sections[("__TEXT", "__text")]
    return text["addr"], text["size"], text["data"]

def nm_by_addr(path):
    by = collections.defaultdict(list)
    with open(path, errors="replace") as f:
        for line in f:
            parts = line.rstrip("\n").split(" ", 2)
            if len(parts) < 3 or parts[1] not in ("T", "t"):
                continue
            try:
                a = int(parts[0], 16)
            except ValueError:
                continue
            if parts[2] == "__mh_execute_header":
                continue
            by[a].append(parts[2])
    return by

INSN = re.compile(r"^\s*([0-9a-f]+):\s*(\S.*?)\s*$")
HEX = re.compile(r"0x[0-9a-f]+")
BRANCH = {"b", "bl", "cbz", "cbnz", "tbz", "tbnz", "br", "blr"}

def disassemble(path):
    out = subprocess.run([OBJDUMP, "-d", "--section=__text", "--no-show-raw-insn", path],
                         capture_output=True, text=True, errors="replace")
    if out.returncode != 0:
        raise InputError(f"objdump failed on {path}: {out.stderr[:500]}")
    insns = {}
    for line in out.stdout.splitlines():
        m = INSN.match(line)
        if not m:
            continue
        txt = re.sub(r"\s*<[^>]*>\s*$", "", m.group(2))   # drop <symbol+off> annotations
        txt = re.sub(r"\s*;.*$", "", txt)                  # drop comments
        txt = re.sub(r"\s+", " ", txt).strip()
        insns[int(m.group(1), 16)] = txt
    return insns

NODEF = {"cmp", "cmn", "tst", "ccmp", "ccmn", "ret", "br", "blr", "b", "bl", "cbz", "cbnz", "tbz", "tbnz",
         "prfm", "nop", "brk", "dmb", "dsb", "isb", "hint", "fcmp", "fccmp", "udf"}
CALLER_SAVED = {f"x{i}" for i in range(0, 19)} | {f"w{i}" for i in range(0, 19)}
IMM = re.compile(r"#-?0x[0-9a-f]+|#-?\d+")
CONSTANT_SECTIONS = {"__cstring", "__const", "__literal4", "__literal8", "__literal16", "__oslogstring"}
PAIR_LOADS = {"ldp", "ldpsw", "ldnp"}
SP_LOADS = {"ldr", "ldp", "ldpsw", "ldnp"}
SP_BASE = re.compile(r"\[sp[\],]")
# A register post-index also changes the tracked base; no dynamic address is proved.
WRITEBACK = re.compile(
    r"\[\s*(\w+)\s*(?:,\s*#-?(?:0x[0-9a-f]+|\d+)\s*)?\]\s*"
    r"(?:!|,\s*(?:#-?(?:0x[0-9a-f]+|\d+)|x(?:[12]?\d|30)\b))"
)
CONSTANT_USERS = {"add", "ldr", "ldrb", "ldrh", "ldrsw", "ldp"}
DATA_DEPENDENCIES = {
    "__cfstring": {"__TEXT,__cstring", "__TEXT,__ustring"},
    "__objc_selrefs": {"__TEXT,__objc_methname"},
    "__objc_classrefs": {"__DATA,__objc_data"},
    "__objc_superrefs": {"__DATA,__objc_data"},
}
TIER_ORDER = {"exact": 0, "normalised": 1, "different": 2}


def data_section(sections, address):
    for (segment, section), entry in (sections or {}).items():
        if (segment in ("__DATA", "__DATA_CONST") and section != "__got"
                and entry["addr"] <= address < entry["addr"] + entry["size"]):
            return segment + "," + section
    return None


def unverified_data(references, section_records):
    """Return changed direct/transitive sections; absent on both sides is harmless."""
    equality = {entry["name"]: entry["byte_equal"] for entry in section_records}
    pending, visited, changed = list(references), set(), set()
    while pending:
        name = pending.pop()
        if name in visited:
            continue
        visited.add(name)
        if not equality.get(name, name not in references):
            changed.add(name)
        pending.extend(DATA_DEPENDENCIES.get(name.split(",", 1)[1], ()))
    return sorted(changed)


def nested_symbol(parent, candidate):
    if parent.startswith(("_$s", "$s", "_$S", "$S", "__T", "_T")):
        return candidate != parent and candidate.startswith(parent)
    block = re.fullmatch(r"___(?:\d+)?(.+?)_block_invoke(?:_?\d+)?", candidate)
    return bool(block and block[1] == parent.removeprefix("_"))


def roll_up_units(records, all_names):
    """Roll up paired aliases once; missing nested symbols withhold certification."""
    by_name = {name: record for record in records for name in record["aliases"]}
    names = sorted(all_names)
    blocks = collections.defaultdict(list)
    for name in names:
        block = re.fullmatch(r"___(?:\d+)?(.+?)_block_invoke(?:_?\d+)?", name)
        if block:
            blocks[block[1]].append(name)
    for record in records:
        members = set(record["aliases"])
        for parent in record["aliases"]:
            if parent.startswith(("_$s", "$s", "_$S", "$S", "__T", "_T")):
                start = bisect.bisect_left(names, parent)
                for index in range(start, len(names)):
                    candidate = names[index]
                    if not candidate.startswith(parent):
                        break
                    if nested_symbol(parent, candidate):
                        members.add(candidate)
            else:
                members.update(blocks.get(parent.removeprefix("_"), ()))
        member_records = {by_name[name]["name"]: by_name[name] for name in members if name in by_name}
        missing = sorted(members - by_name.keys())
        worst = max((r["tier"] for r in member_records.values()), key=TIER_ORDER.get)
        if missing:
            worst = "different"
        causes = [dict(name=r["name"], reason=r["reason"]) for r in member_records.values()
                  if r["tier"] == "different"]
        causes.extend(dict(name=name, reason="unpaired-member") for name in missing)
        record["members"] = sorted(members)
        record["unit_tier"] = worst
        record["unit_reason"] = sorted(causes, key=lambda r: r["name"]) or None
        record["unit_data_sections"] = sorted({s for r in member_records.values() for s in r["data_sections"]})
        record["unit_data_unverified_sections"] = sorted({s for r in member_records.values()
                                                          for s in r["data_unverified_sections"]})
    for record in records:
        record["data_unverified"] = bool(record["unit_data_unverified_sections"])
        record["certified"] = record["unit_tier"] != "different" and not record["data_unverified"]


def path_length_difference(left, right, a_root, b_root):
    if not a_root or not b_root or len(left) != len(right):
        return False
    delta = abs(len(a_root) - len(b_root))
    if not delta:
        return False
    changed = False
    for a, b in zip(left, right):
        if a == b:
            continue
        if (a.split()[0] not in {"mov", "movz", "movk", "add", "sub"}
                or IMM.sub("#IMM", a) != IMM.sub("#IMM", b)):
            return False
        a_values, b_values = IMM.findall(a), IMM.findall(b)
        differences = [abs(int(x[1:], 0) - int(y[1:], 0)) for x, y in zip(a_values, b_values) if x != y]
        if not differences or any(value != delta for value in differences):
            return False
        changed = True
    return changed


def constant_token(sections, address, source_root=None):
    """Return a content digest token for an address in a supported constant section."""
    info = constant_info(sections, address, source_root)
    return "CONST:" + info[1] if info else None


def constant_info(sections, address, source_root=None):
    """Return (section, digest) for an address in a supported constant section."""
    for (segment, section), entry in (sections or {}).items():
        if segment != "__TEXT" or section not in CONSTANT_SECTIONS:
            continue
        offset = address - entry["addr"]
        data = entry["data"]
        if not 0 <= offset < len(data):
            continue
        if section in ("__cstring", "__oslogstring"):
            end = data.find(b"\0", offset)
            if end < 0:
                raise InputError(f"unterminated string in {segment},{section} at {address:#x}")
            value = data[offset:end + 1]
            if source_root:
                root = source_root.rstrip("/").encode("utf-8")
                if value.startswith(root) and value[len(root):len(root)+1] in (b"/", b"\0"):
                    value = value[len(root):]
        else:
            window = entry.get("constant_window", data)
            if offset + 16 > len(window):
                raise InputError(f"fewer than 16 constant bytes in {segment},{section} at {address:#x}")
            value = window[offset:offset + 16]
        return section, hashlib.sha256(value).hexdigest()[:16]
    return None


def defines_first(mn):
    return not (mn.startswith("st") or mn.startswith("b.") or mn.startswith("bc.") or mn in NODEF)

def normalise(seq, start, end, names=None, sections=None, source_root=None, consts=None, lenient=False,
              data_refs=None, dependencies=None):
    """seq: list of (addr, text) for one function. Returns list of masked strings.
    Page bases: a register written by adrp stays a page base until the register is
    redefined (or clobbered by a call, for caller-saved registers); every memory operand
    based on it without writeback and every unshifted `add dst, page, #imm` gets
    its immediate masked as #LO12. Writeback drops its base and sets the optional
    dependencies dictionary's unverified_constant flag when that base was tracked.
    With lenient=True a load whose address base is sp (callee-saved restores and spill
    reloads) does not pop page bases; it is used only to explain a strict difference."""
    out = []
    pages = {}
    for addr, txt in seq:
        parts = txt.split(" ", 1)
        mn = parts[0]
        ops = parts[1] if len(parts) > 1 else ""
        opl = [o.strip() for o in ops.split(",")] if ops else []
        if mn == "adrp":
            ops = HEX.sub("PAGE", ops)
            target = HEX.search(opl[1]) if len(opl) > 1 else None
            if target is None:
                raise InputError(f"unrecognised adrp operand at {addr:#x}: {txt}")
            pages[opl[0]] = int(target.group(0), 16)
            out.append(mn + " " + ops)
            continue
        writeback = WRITEBACK.search(ops)
        if writeback:
            base = writeback.group(1)
            if base in pages:
                pages.pop(base)
                if dependencies is not None:
                    dependencies["unverified_constant"] = True
        for reg in ([] if writeback else list(pages)):
            if re.search(r"\[" + re.escape(reg) + r"(,| |\])", ops) or (mn == "add" and not re.search(r"\b(?:lsl|lsr)\b", ops)
                    and re.search(r"^\S+,\s*" + re.escape(reg) + r",\s*#", ops)):
                immediate = IMM.search(ops)
                if immediate:
                    token = None
                    offset = int(immediate.group(0)[1:], 0)
                    data_name = data_section(sections, pages[reg] + offset)
                    if data_name:
                        token = "DATA:" + data_name
                        if data_refs is not None:
                            data_refs.add(data_name)
                    if mn in CONSTANT_USERS:
                        info = constant_info(sections, pages[reg] + offset, source_root)
                        if info:
                            token = "CONST:" + info[1]
                            if consts is not None:
                                consts.append((len(out), info[0], info[1]))
                    replacement = "#LO12" + (":" + token if token else "")
                    ops = ops[:immediate.start()] + replacement + ops[immediate.end():]
                break
        if mn == "adr":
            ops = HEX.sub("ADR", ops)
        elif mn.startswith("ldr") and HEX.search(ops) and "[" not in ops:
            ops = HEX.sub("LIT", ops)                      # PC-relative literal load
        elif mn == "bl":
            m = HEX.search(ops)
            if m and names is not None:
                ops = ops[:m.start()] + "CALL:" + callee(names, int(m.group(0), 16)) + ops[m.end():]
            else:
                ops = HEX.sub("EXT", ops)
        elif mn == "b" or mn.startswith("b.") or mn.startswith("bc.") or mn in ("cbz", "cbnz", "tbz", "tbnz"):
            ms = list(HEX.finditer(ops))
            if ms:
                m = ms[-1]                                  # the target is the last operand
                tgt = int(m.group(0), 16)
                if start <= tgt < end:
                    ops = ops[:m.start()] + f"REL{tgt-addr:+d}" + ops[m.end():]
                else:
                    ops = ops[:m.start()] + ("TAIL:" + callee(names, tgt) if names is not None else "EXT") + ops[m.end():]
        if mn in ("bl", "blr"):
            pages = {r: page for r, page in pages.items() if r not in CALLER_SAVED}
        elif lenient and mn in SP_LOADS and SP_BASE.search(ops):
            pass
        elif opl and defines_first(mn):
            dst = opl[0]
            if mn == "mov" and len(opl) == 2 and opl[1] in pages:
                pages[dst] = pages[opl[1]]
            else:
                # a write to wN redefines xN, and a pair load defines both registers
                dests = [dst]
                if mn in PAIR_LOADS and len(opl) > 1:
                    dests.append(opl[1])
                for reg in dests:
                    pages.pop(reg, None)
                    if reg[:1] in ("w", "x") and reg[1:].isdigit():
                        pages.pop("x" + reg[1:], None)
        out.append(mn + " " + ops if ops else mn)
    return out

def callee(names, tgt):
    ns = names.get(tgt)
    return sorted(ns)[0] if ns else "EXT"

def functions(by_addr, text_addr, text_size):
    addrs = sorted(a for a in by_addr if text_addr <= a < text_addr + text_size)
    ranges = {}
    for i, a in enumerate(addrs):
        nxt = addrs[i+1] if i+1 < len(addrs) else text_addr + text_size
        ranges[a] = nxt
    return addrs, ranges


def first_difference(a, b):
    """Include a missing instruction when one stream is a proper prefix."""
    for index in range(max(len(a), len(b))):
        left = a[index] if index < len(a) else None
        right = b[index] if index < len(b) else None
        if left != right:
            return [index, left, right]
    return None


def compare_function(*args, **kwargs):
    """Return (tier, first raw difference, first masked difference)."""
    return classify_function(*args, **kwargs)[:3]


def classify_function(a_bytes, b_bytes, a_seq, b_seq, a_range, b_range,
                      a_names=None, b_names=None, a_sections=None, b_sections=None,
                      a_root=None, b_root=None, a_data=None, b_data=None):
    """Return (tier, raw difference, masked difference, reason); reason is set only for
    the different tier: constant, restored-page-base, unverified-constant, path-length or instruction."""
    dependencies = {}
    if a_bytes == b_bytes:
        # Identical bytes are exact only if every resolvable referenced constant matches.
        if len(a_seq) * 4 != len(a_bytes) or len(b_seq) * 4 != len(b_bytes):
            raise InputError("incomplete instruction stream for an identical-bytes function")
        a_consts, b_consts = [], []
        normalise(a_seq, *a_range, a_names, a_sections, a_root, a_consts, data_refs=a_data, dependencies=dependencies)
        normalise(b_seq, *b_range, b_names, b_sections, b_root, b_consts, data_refs=b_data, dependencies=dependencies)
        if dependencies.get("unverified_constant"):
            return "different", None, None, "unverified-constant"
        if a_consts == b_consts:
            return "exact", None, None, None
        diffs = []
        for index in range(max(len(a_consts), len(b_consts))):
            left = a_consts[index] if index < len(a_consts) else None
            right = b_consts[index] if index < len(b_consts) else None
            if left != right:
                diffs.append(dict(
                    instruction_index=(left or right)[0],
                    sectionA=left[1] if left else None, hashA=left[2] if left else None,
                    sectionB=right[1] if right else None, hashB=right[2] if right else None))
        return "different", None, dict(reason="constant", constants=diffs), "constant"
    if len(a_seq) * 4 != len(a_bytes) or len(b_seq) * 4 != len(b_bytes):
        raise InputError("incomplete instruction stream for a non-exact function")
    a_normal = normalise(a_seq, *a_range, a_names, a_sections, a_root, data_refs=a_data, dependencies=dependencies)
    b_normal = normalise(b_seq, *b_range, b_names, b_sections, b_root, data_refs=b_data, dependencies=dependencies)
    raw_diff = first_difference([text for _, text in a_seq], [text for _, text in b_seq])
    masked_diff = first_difference(a_normal, b_normal)
    if dependencies.get("unverified_constant"):
        return "different", raw_diff, masked_diff, "unverified-constant"
    if masked_diff is None:
        return "normalised", raw_diff, None, None
    reason = "instruction"
    a_lenient = normalise(a_seq, *a_range, a_names, a_sections, a_root, lenient=True)
    b_lenient = normalise(b_seq, *b_range, b_names, b_sections, b_root, lenient=True)
    if a_lenient == b_lenient:
        reason = "restored-page-base"
    elif path_length_difference(a_normal, b_normal, a_root, b_root):
        reason = "path-length"
    return "different", raw_diff, masked_diff, reason


def section_comparison(a, b):
    results = []
    for key in sorted(set(a) | set(b)):
        sides = {}
        for label, entries in (("A", a), ("B", b)):
            entry = entries.get(key)
            sides[label] = (dict(size=entry["size"], stored_size=len(entry["data"]),
                                 sha256=hashlib.sha256(entry["data"]).hexdigest(),
                                 zero_fill=entry.get("zero_fill", False)) if entry else None)
        equal = key in a and key in b and a[key]["data"] == b[key]["data"] and a[key]["size"] == b[key]["size"]
        results.append(dict(name=",".join(key) if isinstance(key, tuple) else key,
                            A=sides["A"], B=sides["B"], byte_equal=equal))
    return results


def analyse(args, baseline_normalise=None):
    started = time.monotonic()
    sides = {}
    roots = {}
    for value in args.source_root:
        side, separator, root = value.partition("=")
        if separator != "=" or side not in ("A", "B") or not root.startswith("/") or root == "/":
            raise InputError("source roots must be A=/absolute/path or B=/absolute/path")
        if side in roots:
            raise InputError(f"duplicate source root for {side}")
        roots[side] = root
    for side, (bin_path, nm_path) in (("A", (args.a_bin, args.a_nm)), ("B", (args.b_bin, args.b_nm))):
        sections, segments = macho_sections(bin_path)
        text = sections[("__TEXT", "__text")]
        taddr, tsize, tbytes = text["addr"], text["size"], text["data"]
        by = nm_by_addr(nm_path)
        addrs, ranges = functions(by, taddr, tsize)
        ins = disassemble(bin_path)
        name_to_addr = {}
        for address in addrs:
            for name in by[address]:
                name_to_addr.setdefault(name, address)
        sides[side] = dict(taddr=taddr, tsize=tsize, tbytes=tbytes, by=by, addrs=addrs,
                           ranges=ranges, ins=ins, names=name_to_addr,
                           sections=sections, segments=segments)
    a, b = sides["A"], sides["B"]
    section_records = section_comparison(a["sections"], b["sections"])
    common = sorted(set(a["names"]) & set(b["names"]))
    seen_pairs = set()
    tiers = collections.Counter()
    buckets = collections.defaultdict(collections.Counter)
    examples = {"normalised": [], "different": []}
    non_exact = []
    records = []
    paired_records = {}
    baseline_tiers = collections.Counter()
    baseline_changes = []
    reasons = collections.Counter()
    only_a = sorted(set(a["names"]) - set(b["names"]))
    only_b = sorted(set(b["names"]) - set(a["names"]))
    unpaired = dict(A_only=len(only_a), B_only=len(only_b), A_names=only_a[:50], B_names=only_b[:50])
    for name in common:
        pa, pb = a["names"][name], b["names"][name]
        if (pa, pb) in seen_pairs:
            paired_records[(pa, pb)]["aliases"].append(name)
            continue
        seen_pairs.add((pa, pb))
        ea, eb = a["ranges"][pa], b["ranges"][pb]
        ba = a["tbytes"][pa-a["taddr"]:ea-a["taddr"]]
        bb = b["tbytes"][pb-b["taddr"]:eb-b["taddr"]]
        sa = [(x, a["ins"][x]) for x in range(pa, ea, 4) if x in a["ins"]]
        sb = [(x, b["ins"][x]) for x in range(pb, eb, 4) if x in b["ins"]]
        message = None
        a_data, b_data = set(), set()
        try:
            tier, raw_diff, masked_diff, reason = classify_function(
                ba, bb, sa, sb, (pa, ea), (pb, eb),
                a["by"] if args.callee_names else None, b["by"] if args.callee_names else None,
                a["sections"], b["sections"], roots.get("A"), roots.get("B"), a_data, b_data)
        except InputError as error:
            tier, raw_diff, masked_diff, reason = "different", None, None, "incomplete-stream"
            message = str(error)
        if tier == "different":
            reasons[reason] += 1
        if baseline_normalise is not None:
            baseline_tier = "exact"
            if ba != bb:
                old_a = baseline_normalise(sa, pa, ea, a["by"] if args.callee_names else None)
                old_b = baseline_normalise(sb, pb, eb, b["by"] if args.callee_names else None)
                baseline_tier = "normalised" if old_a == old_b else "different"
            baseline_tiers[baseline_tier] += 1
            if baseline_tier != tier:
                without_a = normalise(sa, pa, ea, a["by"] if args.callee_names else None)
                without_b = normalise(sb, pb, eb, b["by"] if args.callee_names else None)
                without_tier = "normalised" if without_a == without_b else "different"
                if ba == bb:
                    change_reason = "referenced constant content (identical bytes)"
                else:
                    change_reason = ("referenced constant content" if without_tier == baseline_tier
                                     else "normaliser difference requiring review")
                baseline_changes.append(dict(name=name, baseline_tier=baseline_tier,
                                             tier=tier, reason=change_reason,
                                             first_diff=raw_diff, first_masked_diff=masked_diff))
        data_sections = sorted(a_data | b_data)
        changed_data = unverified_data(data_sections, section_records)
        entry = dict(name=name, aliases=[name], addressA=pa, addressB=pb, sizeA=len(ba), sizeB=len(bb),
                     tier=tier, reason=reason, first_diff=raw_diff, first_masked_diff=masked_diff,
                     data_sections=data_sections, data_sectionsA=sorted(a_data), data_sectionsB=sorted(b_data),
                     data_unverified_sections=changed_data, data_unverified=bool(changed_data))
        if message is not None:
            entry["message"] = message
        records.append(entry)
        paired_records[(pa, pb)] = entry
        if tier != "exact":
            if len(examples[tier]) < 12:
                examples[tier].append(entry)
            if args.list_all:
                non_exact.append(entry)
        tiers[tier] += 1
        n = len(ba)
        bucket = "<=16" if n <= 16 else "<=64" if n <= 64 else "<=256" if n <= 256 else ">256"
        buckets[bucket][tier] += 1
    with_units = getattr(args, "units", False)
    if with_units:
        roll_up_units(records, set(a["names"]) | set(b["names"]))
    result = dict(status="ok", label=args.label, callee_names=args.callee_names,
                  A=args.a_bin, B=args.b_bin, paired_functions=len(seen_pairs), unpaired=unpaired,
                  A_functions=len(a["addrs"]), B_functions=len(b["addrs"]),
                  paired_names=len(common), alias_pairs_deduplicated=len(common)-len(seen_pairs),
                  tiers={tier: tiers[tier] for tier in ("exact", "normalised", "different")},
                  different_reasons=dict(reasons),
                  data_referencing=sum(bool(r["data_sections"]) for r in records),
                  data_unverified=sum(r["data_unverified"] for r in records),
                  functions=records,
                  by_size_bucket={key: dict(value) for key, value in buckets.items()},
                  examples=examples, source_roots=roots,
                  seconds=round(time.monotonic()-started, 1))
    if args.list_all:
        result["non_exact"] = non_exact
    if args.sections:
        result["sections"] = section_records
        result["segments"] = section_comparison(a["segments"], b["segments"])
    if with_units:
        unit_counts = collections.Counter(r["unit_tier"] for r in records)
        result["unit_tiers"] = {tier: unit_counts[tier] for tier in TIER_ORDER}
        result["unit_data_referencing"] = sum(bool(r["unit_data_sections"]) for r in records)
        result["certified"] = sum(r["certified"] for r in records)
    else:
        result["certified"] = None  # Unit membership is required for certification.
    if baseline_normalise is not None:
        result["baseline_tiers"] = {tier: baseline_tiers[tier] for tier in ("exact", "normalised", "different")}
        result["baseline_tier_changes"] = baseline_changes
    return result


class JSONArgumentParser(argparse.ArgumentParser):
    def error(self, message):
        raise InputError(message)


def main(argv=None):
    parser = JSONArgumentParser(description=__doc__)
    for name in ("a_bin", "a_nm", "b_bin", "b_nm", "out_path"):
        parser.add_argument(name)
    parser.add_argument("label", nargs="?", default="")
    parser.add_argument("--callee-names", action="store_true")
    parser.add_argument("--list-all", action="store_true")
    parser.add_argument("--sections", action="store_true")
    parser.add_argument("--units", action="store_true")
    parser.add_argument("--source-root", action="append", default=[])
    args = None
    try:
        args = parser.parse_args(argv)
        result = analyse(args)
        code = 0
    except Exception as error:
        result = dict(status="error", error_type=type(error).__name__, error=str(error))
        code = 2
    if args is not None:
        try:
            with open(args.out_path, "w") as output:
                json.dump(result, output, indent=1)
                output.write("\n")
        except OSError as error:
            result = dict(status="error", error_type=type(error).__name__, error=str(error))
            code = 2
    print(json.dumps(result))
    return code


if __name__ == "__main__":
    sys.exit(main())
