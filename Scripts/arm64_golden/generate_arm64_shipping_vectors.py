#!/usr/bin/env python3
"""Generate the MS-24 golden decode vectors: AArch64 families that ship in macOS code.

Families: PAC 1716 hints, the Xn|SP modifier of PAC/AUT/PACGA and the MTE STG family,
LDRAA/LDRAB, FJCVTZS, CRC32, FHM, CSSC (min/max, ABS/CNT/CTZ), MTE/base DC operations, BTI, SB,
FlagM (CFINV/XAFLAG/AXFLAG, SETF8/SETF16, RMIF), and the MTE/PAuth system registers in MRS/MSR
plus MSR TCO, #imm. The corpus also assembles the upstream LLVM MC test files of these families
(llvm_mc_inputs/, unchanged copies at llvm-project 9b9e3f065b36, Apache-2.0 WITH LLVM-exception,
see llvm_mc_inputs/LLVM-LICENSE.TXT) as assembly-text input only; their words are labelled
`llvm-mc:<file>`. Lines the Apple assembler rejects are skipped.

Ground truth is the local Apple toolchain in GENERIC syntax: every vector is assembled with
`xcrun clang -c -target aarch64-none-elf` and disassembled with `xcrun llvm-objdump` on the ELF
object. (Mach-O objdump uses Apple's syntax variant, which drops operands for some forms.)
Nothing is hand-encoded.

Outputs (under MacScope/Tests/CoreTests/GoldenFixtures/arm64-shipping-vectors/):
  vectors.tsv   family  word  mnemonic  operands  source
  boundary.tsv  word  mnemonic  operands   (single-bit flips of every vector word, plus a
                register-edge sweep; `<unknown>` where objdump rejects the word)

usage: Scripts/arm64_golden/generate_arm64_shipping_vectors.py [--check]
"""
from __future__ import annotations

import argparse
import pathlib
import re
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[2]
OUT = ROOT / "MacScope" / "Tests" / "CoreTests" / "GoldenFixtures" / "arm64-shipping-vectors"
MC_INPUTS = pathlib.Path(__file__).resolve().parent / "llvm_mc_inputs"
TARGET = "aarch64-none-elf"
MARCH = "armv9.4-a+memtag+crc+fp16fml+bf16+cssc+sb+flagm+pauth"
MATTR = "+ccpp,+ccdp,+mte,+crc,+fp16fml,+bf16,+cssc,+sb,+flagm,+altnzcv,+pauth,+jsconv,+bti"
REGS = ("x0", "x7", "x17", "x30")


def families() -> list[tuple[str, str]]:
    rows: list[tuple[str, str]] = []
    rows += [("pac-1716", m) for m in ("pacia1716", "pacib1716", "autia1716", "autib1716")]
    for m in ("pacia", "pacib", "pacda", "pacdb", "autia", "autib", "autda", "autdb"):
        rows += [("pac-sp", f"{m} {d}, {n}") for d, n in (("x0", "sp"), ("x30", "sp"), ("x1", "x2"), ("xzr", "sp"))]
    rows += [("pac-sp", f"pacga {d}, {n}, {m}") for d, n, m in
             (("x8", "x9", "sp"), ("x0", "x1", "x2"), ("xzr", "xzr", "sp"), ("x30", "xzr", "x3"))]
    for m in ("stg", "stzg", "st2g", "stz2g"):
        for t, n in (("sp", "sp"), ("sp", "x1"), ("x3", "sp"), ("x0", "x1")):
            rows += [("mte-stg", f"{m} {t}, [{n}]"), ("mte-stg", f"{m} {t}, [{n}, #-4096]"),
                     ("mte-stg", f"{m} {t}, [{n}, #4080]!"), ("mte-stg", f"{m} {t}, [{n}], #16")]
    for m in ("ldraa", "ldrab"):
        for t, n in (("x0", "x1"), ("xzr", "sp"), ("x30", "x29")):
            for off in (0, 8, -8, 4088, -4096, 256):
                rows.append(("ldra", f"{m} {t}, [{n}, #{off}]"))
                rows.append(("ldra", f"{m} {t}, [{n}, #{off}]!"))
    rows += [("fjcvtzs", f"fjcvtzs {w}, {d}") for w, d in (("w0", "d0"), ("w5", "d17"), ("wzr", "d31"), ("w30", "d1"))]
    for c in ("", "c"):
        for s in "bhwx":
            for d, n, m in (("w0", "w1", "w2"), ("wzr", "wzr", "wzr"), ("w30", "w19", "w5")):
                rows.append(("crc32", f"crc32{c}{s} {d}, {n}, {m.replace('w', 'x') if s == 'x' else m}"))
    for m in ("fmlal", "fmlsl", "fmlal2", "fmlsl2"):
        for q in ((".2s", ".2h"), (".4s", ".4h")):
            rows.append(("fhm", f"{m} v0{q[0]}, v1{q[1]}, v31{q[1]}"))
            rows.append(("fhm", f"{m} v31{q[0]}, v30{q[1]}, v2{q[1]}"))
            for i in (0, 3, 5, 7):
                rows.append(("fhm", f"{m} v{i}{q[0]}, v{31 - i}{q[1]}, v{15 - i}.h[{i}]"))
    for m in ("smax", "umax", "smin", "umin"):
        for r in ("x", "w"):
            rows.append(("cssc", f"{m} {r}1, {r}2, {r}3"))
            rows.append(("cssc", f"{m} {r}zr, {r}zr, {r}zr"))
            for imm in ((-128, 0, 3, 127) if m.startswith("s") else (0, 3, 128, 255)):
                rows.append(("cssc", f"{m} {r}1, {r}30, #{imm}"))
    dc = ("ivac isw igvac igsw igdvac igdsw csw cgsw cgdsw cisw cigsw cigdsw zva gva gzva cvac cgvac "
          "cgdvac cvau cvap cgvap cgdvap cvadp cgvadp cgdvadp civac cigvac cigdvac").split()
    rows += [("dc", f"dc {op}, {r}") for op in dc for r in ("x0", "x17", "xzr")]
    rows += [("system", m) for m in ("bti", "bti c", "bti j", "bti jc", "sb", "cfinv", "xaflag", "axflag")]
    for m in ("abs", "cnt", "ctz"):
        for r in ("x", "w"):
            rows += [("cssc", f"{m} {r}{d}, {r}{n}") for d, n in (("0", "1"), ("zr", "zr"), ("30", "17"))]
    rows += [("flagm", f"{m} {w}") for m in ("setf8", "setf16") for w in ("w0", "w1", "w17", "wzr")]
    rows += [("flagm", f"rmif {x}, #{s}, #{k}") for x in ("x0", "x1", "x30", "xzr")
             for s, k in ((0, 0), (63, 15), (1, 8), (32, 1))]
    sysregs = ("tco gcr_el1 rgsr_el1 tfsr_el1 tfsre0_el1 tfsr_el2 tfsr_el12 tfsr_el3 apiakeylo_el1 apiakeyhi_el1 "
               "apibkeylo_el1 apibkeyhi_el1 apdakeylo_el1 apdakeyhi_el1 apdbkeylo_el1 apdbkeyhi_el1 "
               "apgakeylo_el1 apgakeyhi_el1").split()
    for reg in sysregs + ["gmid_el1"]:
        rows += [("sysreg", f"mrs {x}, {reg}") for x in ("x0", "x17", "xzr")]
    for reg in sysregs:
        rows += [("sysreg", f"msr {reg}, {x}") for x in ("x0", "x17", "xzr")]
    rows += [("sysreg", "msr tco, #0"), ("sysreg", "msr tco, #1")]
    rows += [("sysreg", f".inst 0x{0xd503409f | crm << 8:08x}") for crm in range(2, 16)]  # msr TCO, #2..#15
    return rows


def mc_rows() -> list[tuple[str, str]]:
    """Instruction lines of the vendored LLVM MC files (comments, RUN lines and directives dropped)."""
    rows: list[tuple[str, str]] = []
    for path in sorted(MC_INPUTS.glob("*.s")):
        for line in path.read_text().splitlines():
            text = line.split("//")[0].strip()
            if text and not text.startswith((".", "#")):
                rows.append((f"llvm-mc:{path.name}", text))
    return rows


def assemblable(rows: list[tuple[str, str]]) -> list[tuple[str, str]]:
    """Drop the lines the Apple assembler rejects (the MC files carry negative tests too)."""
    error = re.compile(r"^.*?v\.s:(\d+):\d+: error:", re.M)
    while True:
        with tempfile.TemporaryDirectory() as tmp:
            s = pathlib.Path(tmp, "v.s")
            s.write_text(".text\n" + "".join(f"{a}\n" for _, a in rows))
            result = subprocess.run(["xcrun", "clang", "-c", "-target", TARGET, f"-march={MARCH}", str(s),
                                     "-o", str(pathlib.Path(tmp, "v.o"))], capture_output=True, text=True)
        bad = {int(n) - 2 for n in error.findall(result.stderr)}
        if result.returncode == 0:
            return rows
        assert bad, result.stderr
        rows = [r for i, r in enumerate(rows) if i not in bad]


def run(cmd: list[str]) -> str:
    return subprocess.run(cmd, check=True, capture_output=True, text=True).stdout


LINE = re.compile(r"^\s*([0-9a-f]+):\s+([0-9a-f]{8})\s+(\S+)\s*(.*?)\s*$")


def disassemble(source: str) -> list[tuple[str, str, str]]:
    with tempfile.TemporaryDirectory() as tmp:
        s, o = pathlib.Path(tmp, "v.s"), pathlib.Path(tmp, "v.o")
        s.write_text(".text\n" + source)
        run(["xcrun", "clang", "-c", "-target", TARGET, f"-march={MARCH}", str(s), "-o", str(o)])
        raw = run(["xcrun", "llvm-objdump", "-d", f"--mattr={MATTR}", str(o)])
    rows = []
    for line in raw.splitlines():
        m = LINE.match(line)
        if m:
            mnemonic, operands = m.group(3), m.group(4)
            if mnemonic == "<unknown>":
                operands = ""
            rows.append((m.group(2), mnemonic, re.sub(r"\s+", " ", operands)))
    return rows


def generate() -> dict[str, str]:
    fam = families() + assemblable(mc_rows())
    decoded = disassemble("".join(f"{a}\n" for _, a in fam))
    assert len(decoded) == len(fam), (len(decoded), len(fam))
    clang = run(["xcrun", "clang", "--version"]).splitlines()[0]
    objdump = next(l.strip() for l in run(["xcrun", "llvm-objdump", "--version"]).splitlines() if "version" in l)
    header = (f"# generated by Scripts/arm64_golden/generate_arm64_shipping_vectors.py; {clang}; {objdump}; "
              f"xcrun clang -c -target {TARGET} -march={MARCH}; xcrun llvm-objdump -d --mattr={MATTR} (generic syntax)\n")
    vectors = "# family\tword\tmnemonic\toperands\tsource\n" + header
    words: list[int] = []
    for (family, asm), (word, mnemonic, operands) in zip(fam, decoded):
        vectors += f"{family}\t{word}\t{mnemonic}\t{operands}\t{asm}\n"
        words.append(int(word, 16))
    probes: list[int] = []
    seen = set(words)
    for w in dict.fromkeys(words):
        for bit in range(32):
            f = w ^ (1 << bit)
            if f not in seen:
                seen.add(f)
                probes.append(f)
        for field in (0, 5, 10, 16):  # register-edge sweep of each 5-bit register field
            for v in (0, 1, 30, 31):
                f = (w & ~(0x1f << field)) | (v << field)
                if f not in seen:
                    seen.add(f)
                    probes.append(f)
    decoded = disassemble("".join(f".inst 0x{p:08x}\n" for p in probes))
    assert len(decoded) == len(probes)
    boundary = "# word\tmnemonic\toperands\n" + header.replace("# generated", "# bit flips + register sweep; generated")
    for word, mnemonic, operands in decoded:
        boundary += f"{word}\t{mnemonic}\t{operands}\n"
    return {"vectors.tsv": vectors, "boundary.tsv": boundary}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    files = generate()
    if args.check:
        stale = [n for n, t in files.items() if not (OUT / n).exists() or (OUT / n).read_text() != t]
        if stale:
            print("stale:", ", ".join(stale), file=sys.stderr)
            return 1
        return 0
    OUT.mkdir(parents=True, exist_ok=True)
    for name, text in files.items():
        (OUT / name).write_text(text)
    print({n: t.count("\n") for n, t in files.items()})
    return 0


if __name__ == "__main__":
    sys.exit(main())
