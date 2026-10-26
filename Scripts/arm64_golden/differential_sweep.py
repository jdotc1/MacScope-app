#!/usr/bin/env python3
"""MS-23 differential sweep: MacScope's ARM64Decoder against Apple llvm-objdump.

An offline tooling oracle (stdlib only). Every word is
  1. assembled with `.inst` by `xcrun clang -c -target aarch64-none-elf` (ELF, so objdump prints
     LLVM's generic syntax; Mach-O objdump uses Apple's variant, which drops operands for
     rmif/setf8/setf16 and the RCPC3 SIMD offsets),
  2. disassembled by `xcrun llvm-objdump -d --print-imm-hex --mattr=<MATTR>` at BASE
     (`--adjust-vma`, default 0x100000000, so PC-relative targets never underflow), and
  3. decoded by MacScope's `ARM64Decoder` through a standalone `swiftc -O -swift-version 6` probe
     built from `--decoder-sources` (default: this checkout) at the same BASE.

Each word is classified as
  match          both decode, normalised text identical
  mismatch       both decode, text differs (aliases, operand spelling, or a wrong instruction)
  over-decode    MacScope decodes, LLVM rejects (reserved/unallocated encoding accepted)
  gap            LLVM decodes, MacScope prints `unknown`
  both-reject    neither decodes
Normalisation: lower case, `<symbol>` annotations and `//` comments dropped, whitespace collapsed,
address padding removed (`0x0*([0-9a-f]+)` -> `0x\\1`).

Words: N seeded uniform random words, plus `--per-class` structured words for every entry of
STRUCTURED_CLASSES (fixed bits from the class mask/value, the rest random). Duplicates are dropped.

Outputs in --out (swept data is NOT tracked; point --out at a scratch directory):
  sweep.tsv     word  source  category  group  llvm  macscope
  summary.txt   header (seed, N, tool versions, exact command, decoder identity) + ranked tables
  summary.json  the same counts, machine-readable

usage: Scripts/arm64_golden/differential_sweep.py --out DIR [--seed 20261012] [-n 300000]
           [--per-class 3000] [--base 0x100000000] [--decoder-sources DIR] [--probe BIN] [--jobs 4]
           [--words-file FILE]
"""
from __future__ import annotations

import argparse
import collections
import concurrent.futures
import hashlib
import json
import pathlib
import random
import re
import shlex
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[2]
TARGET = "aarch64-none-elf"
MATTR = ",".join((
    "+v9.6a", "+sve2p2", "+sme2p2", "+mops", "+the", "+d128", "+mte", "+pauth-lr", "+lse128", "+rcpc3",
    "+cssc", "+lsui", "+cmpbr", "+fp16fml", "+bf16", "+i8mm", "+f64mm", "+sb", "+flagm", "+altnzcv",
    "+jsconv", "+crc", "+ls64", "+lut", "+fp8", "+fp8fma", "+fp8dot2", "+fp8dot4", "+sme-f8f16",
    "+sme-f8f32", "+sve-b16b16", "+sme-b16b16", "+sme-f16f16", "+sme-f64f64", "+sme-i16i64",
    "+sme-lutv2", "+sve-aes2", "+sve-bfscale", "+sve-f16f32mm", "+ssve-aes", "+occmo", "+pcdphint",
    "+rme", "+tme", "+brbe", "+spe", "+ete", "+trbe", "+xs", "+wfxt", "+hbc", "+chk", "+gcs", "+ite",
    "+rcpc-immo", "+lse", "+rdm", "+fullfp16", "+dotprod", "+complxnum", "+predres", "+specres2",
    "+ccdp", "+ccpp", "+rand", "+sm4", "+sha3", "+aes", "+sha2", "+sve-sm4", "+sve-sha3", "+sve-aes",
    "+sve-bitperm", "+cpa", "+faminmax", "+tlbiw", "+lsfe", "+f8f16mm", "+f8f32mm", "+sme-mop4",
    "+sme-tmop", "+ssve-fp8fma", "+ssve-fp8dot2", "+ssve-fp8dot4", "+mec", "+nmi", "+spe-eef",
    "+tlb-rmi", "+ras", "+rasv2", "+mpam",
))
DEFAULT_SEED = 20261012
DEFAULT_N = 300_000
DEFAULT_BASE = 0x1_0000_0000
CHUNK = 20_000

# (name, mask, value): structured words keep these bits and randomise the rest. Names follow the
# Arm ARM encoding-index groups; the list deliberately covers the known over-decode corridors.
STRUCTURED_CLASSES: tuple[tuple[str, int, int], ...] = (
    ("dpi-pcrel", 0x1F000000, 0x10000000),
    ("dpi-addsub-imm", 0x1F800000, 0x11000000),
    ("dpi-addsub-imm-tags", 0x1F800000, 0x11800000),
    ("dpi-logical-imm", 0x1F800000, 0x12000000),
    ("dpi-movewide", 0x1F800000, 0x12800000),
    ("dpi-bitfield", 0x1F800000, 0x13000000),
    ("dpi-extract", 0x1F800000, 0x13800000),
    ("br-cond", 0xFE000000, 0x54000000),
    ("br-exception", 0xFF000000, 0xD4000000),
    ("br-system", 0xFFC00000, 0xD5000000),
    ("br-uncond-reg", 0xFE000000, 0xD6000000),
    ("br-uncond-imm", 0x7C000000, 0x14000000),
    ("br-cmp-branch", 0x7E000000, 0x34000000),
    ("br-test-branch", 0x7E000000, 0x36000000),
    ("br-cmpbr-imm", 0x7E000000, 0x74000000),
    ("ls-exclusive-ordered", 0x3F000000, 0x08000000),
    ("ls-literal", 0x3B000000, 0x18000000),
    ("ls-rcpc-unscaled", 0x3F200C00, 0x19000000),
    ("ls-pair", 0x3A000000, 0x28000000),
    ("ls-register", 0x3B000000, 0x38000000),
    ("ls-register-unsigned", 0x3B000000, 0x39000000),
    ("ls-simd-struct", 0xBE000000, 0x0C000000),
    ("ls-lookalike-bit25", 0x3A000000, 0x3A000000),
    ("dpr-2src", 0x5FE00000, 0x1AC00000),
    ("dpr-1src", 0x5FE00000, 0x5AC00000),
    ("dpr-logical-shift", 0x1F000000, 0x0A000000),
    ("dpr-addsub-shift", 0x1F200000, 0x0B000000),
    ("dpr-addsub-ext", 0x1F200000, 0x0B200000),
    ("dpr-carry-rmif-setf", 0x1FE00000, 0x1A000000),
    ("dpr-condcmp", 0x1FE00000, 0x1A400000),
    ("dpr-condsel", 0x1FE00000, 0x1A800000),
    ("dpr-3src", 0x1F000000, 0x1B000000),
    ("simd-fp", 0x0E000000, 0x0E000000),
    ("sve", 0x1E000000, 0x04000000),
    ("sme-reserved", 0x1E000000, 0x00000000),
)

# Known reserved-field root causes (MS-23 classes). Each predicate is the reserved condition from
# the Arm ARM; an over-decode or wrong-instruction mismatch matching it is attributed to that class.
KNOWN_CLASSES: tuple[tuple[str, str], ...] = (
    ("addsub-ext-imm3>4", "(w & 0x1f200000) == 0x0b200000 and ((w >> 10) & 7) > 4"),
    ("addsub-ext-opt!=0", "(w & 0x1f200000) == 0x0b200000 and ((w >> 22) & 3) != 0"),
    ("shifted-reg-sf0-imm6>31",
     "((w & 0x9f000000) == 0x0a000000 or (w & 0x9f200000) == 0x0b000000) and (w >> 15) & 1"),
    ("addsub-shift-ror", "(w & 0x1f200000) == 0x0b000000 and ((w >> 22) & 3) == 3"),
    ("bitfield-N!=sf-or-sf0-imm>31",
     "(w & 0x1f800000) == 0x13000000 and (((w >> 31) & 1) != ((w >> 22) & 1)"
     " or ((w >> 31) == 0 and ((w >> 21) & 1 or (w >> 15) & 1)))"),
    ("bitfield-opc=11", "(w & 0x1f800000) == 0x13000000 and ((w >> 29) & 3) == 3"),
    ("extract-N!=sf-or-sf0-imms>31-or-op21/o0",
     "(w & 0x1f800000) == 0x13800000 and (((w >> 31) & 1) != ((w >> 22) & 1)"
     " or ((w >> 31) == 0 and (w >> 15) & 1) or ((w >> 29) & 3) != 0 or (w >> 21) & 1)"),
    ("rmif-as-store", "(w & 0xffe07c10) == 0xba000400"),
    ("condcmp-o2/o3!=0", "(w & 0x3fe00000) == 0x3a400000 and ((w >> 10) & 1 or (w >> 4) & 1)"),
    ("ls-lookalike-bit25", "(w & 0x3a000000) == 0x3a000000"),
    ("pacga-sf0", "(w & 0xffe0fc00) == 0x1ac03000"),
    ("movewide-sf0-hw>=2-or-opc=01",
     "(w & 0x9f800000) == 0x12800000 and (w >> 22) & 1 or (w & 0x7f800000) == 0x32800000"),
    ("3src-op54-or-sf0-long-or-op31",
     "(w & 0x1f000000) == 0x1b000000 and (((w >> 29) & 3) != 0 or (((w >> 21) & 7) != 0 and (w >> 31) == 0)"
     " or ((w >> 21) & 7) in (4, 7) or (((w >> 21) & 7) in (2, 6) and (w >> 15) & 1))"),
    ("exception-op2!=0", "(w & 0xff000000) == 0xd4000000 and (w & 0x1c) != 0"),
    ("cas-rt2!=31-or-casp-odd",
     "(w & 0x3f200000) == 0x08200000 and (((w >> 23) & 1) or (w >> 31) == 0) and (((w >> 10) & 0x1f) != 0x1f"
     " or (not (w >> 23) & 1 and ((w >> 16) & 1 or w & 1)))"),
    ("simd-ldst-struct-bit31/b21/Rm/1d",
     "(w & 0x3e000000) == 0x0c000000 and ((w >> 31) or (((w >> 24) & 1) == 0 and (w >> 21) & 1)"
     " or (((w >> 23) & 1) == 0 and (w >> 16) & 0x1f)"
     " or (((w >> 24) & 1) == 0 and ((w >> 12) & 0xf) in (0, 4, 8) and ((w >> 10) & 3) == 3"
     " and not (w >> 30) & 1))"),
    ("pair-noalloc-opc=01-or-fp-pair-opc=11",
     "(w & 0xff800000) == 0x68000000 or (w & 0xfe000000) == 0xec000000"),
    ("fp-scalar-M/S/ftype=10",
     "(w & 0x5f200000) == 0x1e200000 and ((w >> 10) & 0x3f) != 0"
     " and ((w >> 31) or ((w >> 29) & 1) or ((w >> 22) & 3) == 2)"),
    ("fp-imm-imm5!=0-or-fcmp-op/opc2",
     "(w & 0xff201c00) == 0x1e201000 and (w >> 5) & 0x1f"
     " or (w & 0xff203c00) == 0x1e202000 and (((w >> 14) & 3) or (w & 7))"),
    ("simd-pmul-size!=0", "(w & 0xbf20fc00) == 0x2e209c00 and ((w >> 22) & 3) != 0"),
)
_KNOWN = tuple((name, eval(f"lambda w: bool({expr})")) for name, expr in KNOWN_CLASSES)  # noqa: S307

PROBE_MAIN = r"""
import Foundation
// usage: probe <hexwords-file> <base-address-hex>  -> "word\tmnemonic operands" per line
let args = CommandLine.arguments
let words = try! String(contentsOfFile: args[1], encoding: .utf8).split(separator: "\n").compactMap { UInt32($0, radix: 16) }
let base = UInt64(args[2].replacingOccurrences(of: "0x", with: ""), radix: 16)!
var data = Data(capacity: words.count * 4)
for w in words { var le = w.littleEndian; data.append(Data(bytes: &le, count: 4)) }
let decoded = ARM64Decoder().decode(data, baseAddress: base, maxInstructionCount: Int.max)
guard decoded.count == words.count else {
    FileHandle.standardError.write("probe: \(words.count) words but \(decoded.count) instructions\n".data(using: .utf8)!)
    exit(2)
}
var out = ""
out.reserveCapacity(words.count * 40)
for (w, i) in zip(words, decoded) {
    out += String(format: "%08x", w) + "\t" + i.mnemonic + (i.operands.isEmpty ? "" : " " + i.operands) + "\n"
}
FileHandle.standardOutput.write(out.data(using: .utf8)!)
"""
HEXADDRESS_SHIM = (
    "extension UInt64 { var hexAddress: String { let h = String(self, radix: 16); "
    'return "0x" + String(repeating: "0", count: Swift.max(0, 16 - h.count)) + h } }\n'
)


# ---------------------------------------------------------------------------------------------
# Word generation and grouping


def generate_words(seed: int, n: int, per_class: int) -> list[tuple[int, str]]:
    rng = random.Random(seed)
    words: dict[int, str] = {}
    for _ in range(n):
        words.setdefault(rng.getrandbits(32), "random")
    for name, mask, value in STRUCTURED_CLASSES:
        for _ in range(per_class):
            words.setdefault((rng.getrandbits(32) & ~mask & 0xFFFFFFFF) | value, f"class:{name}")
    return list(words.items())


def decode_group(w: int) -> tuple[str, str]:
    """Top-level Arm ARM decode group (op0 = bits 28:25) and its second-level op fields."""
    op0 = (w >> 25) & 0xF
    if op0 == 0b0000:
        return ("sme" if w >> 31 else "reserved"), f"op0={(w >> 29) & 3:02b}"
    if op0 in (0b0001, 0b0011):
        return "unallocated", ""
    if op0 == 0b0010:
        return "sve", f"op0={(w >> 29) & 7:03b} op1={(w >> 24) & 1}"
    if op0 >> 1 == 0b100:
        return "dp-imm", f"op0={(w >> 22) & 0xf:04b} sf={w >> 31}"
    if op0 >> 1 == 0b101:
        return "branch-sys", f"op0={w >> 29:03b} op1={(w >> 22) & 0xf:04b}"
    if op0 & 0b0101 == 0b0100:
        return "load-store", (f"op0={w >> 28:04b} V={(w >> 26) & 1} op2={(w >> 23) & 3:02b} "
                              f"b21={(w >> 21) & 1} op4={(w >> 10) & 3:02b}")
    if op0 & 0b0111 == 0b0101:
        return "dp-reg", f"op0={(w >> 30) & 1} op1={(w >> 28) & 1} op2={(w >> 21) & 0xf:04b}"
    return "simd-fp", f"op0={w >> 28:04b} op1={(w >> 23) & 3:02b} op2={(w >> 19) & 0xf:04b}"


def known_class(w: int) -> str:
    for name, predicate in _KNOWN:
        if predicate(w):
            return name
    return ""


# ---------------------------------------------------------------------------------------------
# Normalisation and classification

_ANNOTATION = re.compile(r"\s*<[^>]*>")
_COMMENT = re.compile(r"\s*(//|;).*$")
_PADDING = re.compile(r"0x0*([0-9a-f]+)")


def normalize(text: str) -> str:
    text = _ANNOTATION.sub("", text.lower())
    text = _COMMENT.sub("", text)
    text = " ".join(text.replace("\t", " ").split())
    text = re.sub(r"\s*,\s*", ", ", text)
    return _PADDING.sub(r"0x\1", text)


_HEX_IMM = re.compile(r"#(-?)0x([0-9a-f]+)\b")
_LSL12 = re.compile(r"#(\d+), lsl #12\b")


def spelling_only(llvm: str, macscope: str) -> bool:
    """True when a mismatch is presentation only: hex vs decimal immediates, `{ v0 }` vs `{v0}`,
    an explicit zero shift, or `#imm, lsl #12` vs the folded immediate."""
    def loose(text: str) -> str:
        text = normalize(text).replace("{ ", "{").replace(" }", "}")
        text = _HEX_IMM.sub(lambda m: f"#{m.group(1)}{int(m.group(2), 16)}", text)
        text = _LSL12.sub(lambda m: f"#{int(m.group(1)) << 12}", text)
        return re.sub(r", (lsl|lsr|asr|ror|uxtx|uxtw) #0\b", "", text)
    return loose(llvm) == loose(macscope)


def llvm_decodes(text: str) -> bool:
    return bool(text) and not text.startswith("<unknown>")


def macscope_decodes(text: str) -> bool:
    return bool(text) and not text.startswith("unknown")


def classify(llvm: str, macscope: str) -> str:
    lo, mo = llvm_decodes(llvm), macscope_decodes(macscope)
    if lo and mo:
        return "match" if normalize(llvm) == normalize(macscope) else "mismatch"
    if mo:
        return "over-decode"
    if lo:
        return "gap"
    return "both-reject"


GAP_FAMILIES: tuple[tuple[str, str], ...] = (
    ("LSUI (ldt*/stt*, cas*t, swp*t, ld<op>*t)", r"^(ldtp|sttp|ldtnp|sttnp|ldtr?|sttr?|ldt(add|clr|set)|stt(add|clr|set)|swp[a-z]*t|cas[a-z]*t|ldt[a-z]+|stt[a-z]+)\b"),
    ("CMPBR (cb<cc>, cbb<cc>, cbh<cc>)", r"^cb[bh]?(gt|ge|hi|hs|lo|ls|lt|le|eq|ne)\b"),
    ("MOPS/THE/PAuth_LR/D128", r"^(cpy|set[gpme]|rcw|.*sppc|pacm|sysp|tlbip|msrr|mrrs)"),
    ("LSE128/RCPC3/LS64", r"^(ldclrp|ldsetp|swpp|ldiapp|stilp|ld64b|st64b|ldapr|stlr|ldap1|stl1)"),
    ("system/hint/sysreg", r"^(msr|mrs|sys|sysl|hint|dc|ic|at|tlbi|bti|clrbhb|gcs|chkfeat|stshh|stcph|shuh|wfet|wfit|tcancel|tstart|ttest|tcommit|brb|trcit|psb|tsb|esb|dsb|dmb|isb|sb|ssbb|pssbb|xpaclri|apas|cosp|cpp|dvp|cfp|prfm|prfum|prfop|rprfm|pacia|pacib|autia|autib|retaa|retab|eret|drps|dcps|smc|hvc|svc|brk|hlt|tcancel)"),
)


def gap_family(w: int, llvm: str) -> str:
    group, _ = decode_group(w)
    if group == "sve":
        return "SVE/SVE2"
    if group == "sme":
        return "SME/SME2"
    mnemonic = normalize(llvm).split(" ")[0]
    for family, pattern in GAP_FAMILIES:
        if re.match(pattern, mnemonic):
            return family
    if group == "simd-fp":
        return "Advanced SIMD/FP (non-SVE)"
    return f"other:{mnemonic}"


# ---------------------------------------------------------------------------------------------
# Tools


def run(cmd: list[str], **kw) -> str:
    return subprocess.run(cmd, check=True, capture_output=True, text=True, **kw).stdout


def tool_versions() -> dict[str, str]:
    def first(cmd: list[str], pattern: str) -> str:
        try:
            out = subprocess.run(cmd, capture_output=True, text=True).stdout + ""
        except OSError as exc:
            return f"unavailable ({exc})"
        for line in out.splitlines():
            if re.search(pattern, line):
                return line.strip()
        return out.strip().splitlines()[0] if out.strip() else "?"
    return {
        "clang": first(["xcrun", "clang", "--version"], "clang version"),
        "llvm-objdump": first(["xcrun", "llvm-objdump", "--version"], "LLVM version"),
        "llvm-objdump-path": run(["xcrun", "-f", "llvm-objdump"]).strip(),
        "swiftc": first(["xcrun", "swiftc", "--version"], "Swift version"),
    }


_OBJDUMP_LINE = re.compile(r"^\s*([0-9a-f]+):\s+([0-9a-f]{8})\s+(.*)$")


def parse_objdump(text: str) -> list[tuple[int, int, str]]:
    rows = []
    for line in text.splitlines():
        m = _OBJDUMP_LINE.match(line)
        if m:
            rows.append((int(m.group(1), 16), int(m.group(2), 16), m.group(3).strip()))
    return rows


def llvm_chunk(index: int, words: list[int], base: int, workdir: pathlib.Path) -> list[str]:
    """`base` is this chunk's own address (BASE + 4 * CHUNK * index), so PC-relative targets agree."""
    source = workdir / f"chunk{index:04d}.s"
    obj = workdir / f"chunk{index:04d}.o"
    source.write_text("".join(f"  .inst {w:#010x}\n" for w in words), encoding="utf-8")
    run(["xcrun", "clang", "-c", "-target", TARGET, str(source), "-o", str(obj)])
    dump = run(["xcrun", "llvm-objdump", "-d", "--print-imm-hex", f"--adjust-vma={base:#x}",
                f"--mattr={MATTR}", str(obj)])
    rows = parse_objdump(dump)
    if len(rows) != len(words) or any(r[1] != w for r, w in zip(rows, words)):
        raise SystemExit(f"ERROR: objdump chunk {index}: {len(words)} words, {len(rows)} rows")
    for (address, _, _), offset in zip(rows, range(len(words))):
        if address != base + offset * 4:
            raise SystemExit(f"ERROR: objdump chunk {index}: unexpected address {address:#x}")
    obj.unlink()
    source.unlink()
    return [text for _, _, text in rows]


def llvm_decode(words: list[int], base: int, jobs: int, workdir: pathlib.Path) -> list[str]:
    """Chunk k is assembled at offset 0 and dumped at BASE + 4 * CHUNK * k, the address MacScope
    sees for those words in its single contiguous buffer."""
    chunks = [words[i:i + CHUNK] for i in range(0, len(words), CHUNK)]
    with concurrent.futures.ThreadPoolExecutor(max_workers=jobs) as pool:
        results = list(pool.map(lambda a: llvm_chunk(a[0], a[1], base + 4 * CHUNK * a[0], workdir),
                                enumerate(chunks)))
    return [text for chunk in results for text in chunk]


def decoder_files(sources: pathlib.Path) -> list[pathlib.Path]:
    files = sorted((sources / "MacScope/Services/Disassembly").glob("ARM64Decoder*.swift"))
    files += [sources / "MacScope/Services/Disassembly/Disassembler.swift",
              sources / "MacScope/Services/Concurrency/ConcurrentMap.swift",
              sources / "MacScope/Services/Support/HexByteFormatter.swift"]
    missing = [str(f) for f in files if not f.exists()]
    if missing:
        raise SystemExit(f"ERROR: missing decoder sources: {missing}")
    return files


def build_probe(sources: pathlib.Path, cache: pathlib.Path) -> tuple[pathlib.Path, str, list[str]]:
    files = decoder_files(sources)
    digest = hashlib.sha256()
    for f in files:
        digest.update(f.name.encode())
        digest.update(f.read_bytes())
    digest.update(PROBE_MAIN.encode() + HEXADDRESS_SHIM.encode())
    tag = digest.hexdigest()[:16]
    cache.mkdir(parents=True, exist_ok=True)
    binary = cache / f"arm64-decoder-probe-{tag}"
    (cache / "main.swift").write_text(PROBE_MAIN, encoding="utf-8")
    (cache / "hexaddress_shim.swift").write_text(HEXADDRESS_SHIM, encoding="utf-8")
    cmd = ["xcrun", "swiftc", "-O", "-swift-version", "6", "-module-name", "ARM64DecoderProbe",
           "-o", str(binary), *map(str, files), str(cache / "hexaddress_shim.swift"), str(cache / "main.swift")]
    if not binary.exists():
        print(f"building probe ({len(files)} sources) ...", file=sys.stderr)
        subprocess.run(cmd, check=True)
    return binary, tag, cmd


def macscope_decode(probe: pathlib.Path, words: list[int], base: int, workdir: pathlib.Path) -> list[str]:
    path = workdir / "words.hex"
    path.write_text("".join(f"{w:08x}\n" for w in words), encoding="utf-8")
    out = run([str(probe), str(path), f"{base:#x}"])
    rows = [line.split("\t", 1) for line in out.splitlines()]
    if len(rows) != len(words) or any(int(r[0], 16) != w for r, w in zip(rows, words)):
        raise SystemExit("ERROR: probe output does not line up with the input words")
    return [r[1] if len(r) > 1 else "" for r in rows]


def git_identity(sources: pathlib.Path) -> str:
    try:
        head = run(["git", "-C", str(sources), "rev-parse", "HEAD"]).strip()
        dirty = run(["git", "-C", str(sources), "status", "--porcelain", "--",
                     "MacScope/Services/Disassembly"]).strip()
        return head + (" (decoder files modified)" if dirty else "")
    except (subprocess.CalledProcessError, OSError):
        return "not a git checkout"


# ---------------------------------------------------------------------------------------------
# Reporting


def summarise(rows: list[dict]) -> dict:
    categories = collections.Counter(r["category"] for r in rows)
    by_source: dict[str, collections.Counter] = collections.defaultdict(collections.Counter)
    for r in rows:
        by_source["random" if r["source"] == "random" else "structured"][r["category"]] += 1

    def table(selected: list[dict], key) -> list[dict]:
        groups: dict[tuple, list[dict]] = collections.defaultdict(list)
        for r in selected:
            groups[key(r)].append(r)
        out = []
        for k, members in sorted(groups.items(), key=lambda kv: (-len(kv[1]), kv[0])):
            out.append({"key": list(k), "count": len(members),
                        "examples": [[m["word"], m["llvm"], m["macscope"]] for m in members[:3]]})
        return out

    over = [r for r in rows if r["category"] == "over-decode"]
    mism = [r for r in rows if r["category"] == "mismatch"]
    gaps = [r for r in rows if r["category"] == "gap"]
    mnem = lambda t: normalize(t).split(" ")[0]  # noqa: E731
    semantic = [r for r in mism if r["detail"] == "semantic"]
    return {
        "mismatch_detail": dict(collections.Counter(r["detail"] for r in mism)),
        "categories": dict(categories),
        "by_source": {k: dict(v) for k, v in by_source.items()},
        "over_decode_known": table(over, lambda r: (r["known"] or "(unattributed)",)),
        "over_decode_classes": table(over, lambda r: (r["group"], r["fields"], mnem(r["macscope"]))),
        "over_decode_by_mnemonic": table(over, lambda r: (r["group"], mnem(r["macscope"]))),
        "mismatch_known": table([r for r in mism if r["known"]], lambda r: (r["known"],)),
        "mismatch_wrong_instruction": table([r for r in semantic if mnem(r["llvm"]) != mnem(r["macscope"])],
                                            lambda r: (mnem(r["llvm"]), mnem(r["macscope"]))),
        "mismatch_semantic_pairs": table(semantic, lambda r: (mnem(r["llvm"]), mnem(r["macscope"]))),
        "mismatch_spelling_pairs": table([r for r in mism if r["detail"] == "spelling"],
                                         lambda r: (mnem(r["llvm"]), mnem(r["macscope"]))),
        "gap_families": table(gaps, lambda r: (gap_family(int(r["word"], 16), r["llvm"]),)),
        "gap_mnemonics": table(gaps, lambda r: (mnem(r["llvm"]),)),
    }


def render(header: list[str], summary: dict, limit: int = 60) -> str:
    lines = list(header)
    lines.append("")
    lines.append("categories: " + ", ".join(f"{k}={v}" for k, v in sorted(summary["categories"].items())))
    lines.append("mismatch detail: " + ", ".join(f"{k}={v}" for k, v in sorted(summary["mismatch_detail"].items())))
    for source, counts in sorted(summary["by_source"].items()):
        lines.append(f"  {source}: " + ", ".join(f"{k}={v}" for k, v in sorted(counts.items())))
    for title, key in (("over-decode by known reserved-field class", "over_decode_known"),
                       ("over-decode classes (group | fields | MacScope mnemonic)", "over_decode_classes"),
                       ("over-decode by group | MacScope mnemonic", "over_decode_by_mnemonic"),
                       ("mismatches matching a known reserved-field class", "mismatch_known"),
                       ("mismatch, wrong instruction (LLVM | MacScope mnemonic differ)", "mismatch_wrong_instruction"),
                       ("mismatch, semantic (operands differ beyond spelling)", "mismatch_semantic_pairs"),
                       ("mismatch, spelling only (hex/decimal, braces, zero shift)", "mismatch_spelling_pairs"),
                       ("gap families", "gap_families"),
                       ("gap mnemonics (LLVM)", "gap_mnemonics")):
        lines.append("")
        lines.append(f"== {title}")
        for entry in summary[key][:limit]:
            lines.append(f"{entry['count']:>8}  {' | '.join(entry['key'])}")
            for word, llvm, mac in entry["examples"]:
                lines.append(f"            {word}  llvm: {normalize(llvm) or '-'}  ||  macscope: {normalize(mac) or '-'}")
    return "\n".join(lines) + "\n"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--out", type=pathlib.Path, required=True, help="output directory (untracked)")
    parser.add_argument("--seed", type=int, default=DEFAULT_SEED)
    parser.add_argument("-n", type=int, default=DEFAULT_N, help="uniform random words")
    parser.add_argument("--per-class", type=int, default=3000, help="structured words per encoding class")
    parser.add_argument("--base", type=lambda s: int(s, 0), default=DEFAULT_BASE)
    parser.add_argument("--decoder-sources", type=pathlib.Path, default=ROOT,
                        help="checkout whose MacScope/Services/Disassembly/ARM64Decoder*.swift is swept")
    parser.add_argument("--probe", type=pathlib.Path, help="prebuilt probe binary (skips swiftc)")
    parser.add_argument("--words-file", type=pathlib.Path, help="sweep these hex words instead of generating")
    parser.add_argument("--jobs", type=int, default=4)
    args = parser.parse_args(argv)

    args.out.mkdir(parents=True, exist_ok=True)
    if args.words_file:
        items = [(int(t, 16), "file") for t in args.words_file.read_text().split() if t]
        items = list(dict.fromkeys(items))
    else:
        items = generate_words(args.seed, args.n, args.per_class)
    words = [w for w, _ in items]

    if args.probe:
        probe, probe_tag, probe_cmd = args.probe, "prebuilt", ["(prebuilt)", str(args.probe)]
    else:
        probe, probe_tag, probe_cmd = build_probe(args.decoder_sources.resolve(), args.out / "probe")
    with tempfile.TemporaryDirectory() as tmp:
        workdir = pathlib.Path(tmp)
        print(f"llvm-objdump: {len(words)} words ...", file=sys.stderr)
        llvm = llvm_decode(words, args.base, args.jobs, workdir)
        print("macscope probe ...", file=sys.stderr)
        mac = macscope_decode(probe, words, args.base, workdir)

    rows = []
    for (w, source), lt, mt in zip(items, llvm, mac):
        group, fields = decode_group(w)
        category = classify(lt, mt)
        known = known_class(w) if category in ("over-decode", "mismatch") else ""
        detail = ("spelling" if spelling_only(lt, mt) else "semantic") if category == "mismatch" else ""
        rows.append({"word": f"{w:08x}", "source": source, "category": category, "group": group,
                     "fields": fields, "known": known, "detail": detail,
                     "llvm": " ".join(lt.split()), "macscope": " ".join(mt.split())})
    with (args.out / "sweep.tsv").open("w", encoding="utf-8") as fh:
        fh.write("# word\tsource\tcategory\tdetail\tgroup\tfields\tknown\tllvm\tmacscope\n")
        for r in rows:
            fh.write("\t".join(r[k] for k in ("word", "source", "category", "detail", "group", "fields",
                                              "known", "llvm", "macscope")) + "\n")

    versions = tool_versions()
    header = [
        "# MS-23 differential sweep (Scripts/arm64_golden/differential_sweep.py)",
        "# command: " + shlex.join([sys.executable, *sys.argv]),
        f"# seed={args.seed} n_random={args.n} per_class={args.per_class} classes={len(STRUCTURED_CLASSES)} "
        f"unique_words={len(words)} base={args.base:#x}" + (f" words_file={args.words_file}" if args.words_file else ""),
        f"# decoder: {args.decoder_sources.resolve()} @ {git_identity(args.decoder_sources.resolve())}; probe {probe_tag}",
        "# probe build: " + shlex.join(map(str, probe_cmd)),
        f"# assemble: xcrun clang -c -target {TARGET} <chunk>.s   (.inst words, {CHUNK} per chunk)",
        f"# disassemble: xcrun llvm-objdump -d --print-imm-hex --adjust-vma=<{args.base:#x} + 4*{CHUNK}*k> --mattr={MATTR}",
        *(f"# {k}: {v}" for k, v in versions.items()),
    ]
    summary = summarise(rows)
    (args.out / "summary.json").write_text(json.dumps({"header": header, **summary}, indent=1) + "\n",
                                           encoding="utf-8")
    (args.out / "summary.txt").write_text(render(header, summary), encoding="utf-8")
    print(render(header, summary, limit=15))
    return 0


if __name__ == "__main__":
    sys.exit(main())
