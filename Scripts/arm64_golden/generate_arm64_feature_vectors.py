#!/usr/bin/env python3
"""Generate the ARM64 FEAT_PAuth_LR / FEAT_MOPS / FEAT_THE golden decode vectors.

Ground truth is the local Apple toolchain only: every vector is assembled with
`xcrun clang -c -arch arm64 -march=<MARCH>` and disassembled with
`xcrun llvm-objdump -d --mattr=<MATTR>`. Nothing is hand-encoded.

Outputs (both under MacScope/Tests/CoreTests/GoldenFixtures/arm64-feature-vectors/):

  vectors.tsv   one row per assembled instruction:
                  family  address  word  mnemonic  operands  source
                `address` is the instruction's offset in the object (the PC-relative
                label forms are decoded at that address). `operands` is objdump's text
                with any trailing `<symbol+off>` annotation removed.

  boundary.tsv  single-bit-flip neighbours of one representative per encoding group,
                plus a register-edge sweep, assembled with `.inst` and disassembled with
                the same objdump:
                  address  word  mnemonic  operands
                `mnemonic` is `<unknown>` where objdump rejects the word.

usage: Scripts/arm64_golden/generate_arm64_feature_vectors.py [--check]
  --check   regenerate into memory and fail if the checked-in files differ.
"""
from __future__ import annotations

import argparse
import pathlib
import re
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[2]
OUT = ROOT / "MacScope" / "Tests" / "CoreTests" / "GoldenFixtures" / "arm64-feature-vectors"
MARCH = "armv9.4-a+pauth-lr+mops+the+d128+memtag"
MATTR = "+pauth-lr,+mops,+the,+d128,+mte,+rcpc-immo"

ACQ_REL = ["", "a", "al", "l"]
# One base encoding per register-bearing group (taken from vectors.tsv): cpyfp, cpyp, setp,
# setgp, rcwcas, rcwscasp, rcwcasp, rcwswp, rcwsswpp, autiasppcr, retaasppcr, paciasppc.
REGISTER_SWEEP_BASES = (
    0x19010440, 0x1D010440, 0x19C20420, 0x1DC20420, 0x19200841, 0x593C0FE6,
    0x19200C82, 0x3820A041, 0x5921A040, 0xDAC1901E, 0xD65F0BE0, 0xDAC1A3FE,
)


def pauth_lr() -> list[tuple[str, str]]:
    rows = [
        "paciasppc", "pacibsppc", "pacnbiasppc", "pacnbibsppc",
        "pacia171615", "pacib171615", "autia171615", "autib171615",
        "pacm",
    ]
    for reg in ("x0", "x3", "x17", "x30"):
        rows += [f"autiasppcr {reg}", f"autibsppcr {reg}", f"retaasppcr {reg}", f"retabsppcr {reg}"]
    out = [("pauth-lr", r) for r in rows]
    # Immediate (label) forms: imm16 is a backward word offset from the PC, 0...0xffff.
    # `.space` places each instruction a known distance after its label.
    for mnemonic in ("autiasppc", "autibsppc", "retaasppc", "retabsppc"):
        for words_back in (0, 1, 0x401, 0xffff):
            out.append(("pauth-lr-label", f"{mnemonic}:{words_back}"))
    return out


def mops() -> list[tuple[str, str]]:
    out = []
    cpy_options = []
    for rd in ("", "wt", "rt", "t"):
        for wr in ("", "wn", "rn", "n"):
            cpy_options.append(rd + wr)
    regs = [("x0", "x1", "x2"), ("x3", "x17", "x30"), ("x29", "x4", "x9")]
    for base in ("cpyf", "cpy"):
        for opt in cpy_options:
            for stage in ("p", "m", "e"):
                for i, (d, s, n) in enumerate(regs[:2] if opt == "" else regs[:1]):
                    out.append(("mops", f"{base}{stage}{opt} [{d}]!, [{s}]!, {n}!"))
    set_regs = [("x0", "x1", "x2"), ("x5", "x6", "xzr"), ("x29", "x30", "x7")]
    for base in ("set", "setg"):
        for opt in ("", "t", "n", "tn"):
            for stage in ("p", "m", "e"):
                for d, n, s in (set_regs if opt == "" else set_regs[:1]):
                    out.append(("mops", f"{base}{stage}{opt} [{d}]!, {n}!, {s}"))
    return out


def the() -> list[tuple[str, str]]:
    out = []
    singles = [("x0", "x1", "x2"), ("x5", "x7", "sp"), ("x30", "xzr", "x29")]
    for base in ("rcwcas", "rcwscas", "rcwswp", "rcwsswp", "rcwclr", "rcwsclr", "rcwset", "rcwsset"):
        for ar in ACQ_REL:
            for s, t, n in (singles if ar == "" else singles[:1]):
                out.append(("the", f"{base}{ar} {s}, {t}, [{n}]"))
    pairs = [("x0", "x1", "x2", "x3", "x4"), ("x28", "x29", "x6", "x7", "sp")]
    for base in ("rcwcasp", "rcwscasp"):
        for ar in ACQ_REL:
            for s, s1, t, t1, n in (pairs if ar == "" else pairs[:1]):
                out.append(("the-d128", f"{base}{ar} {s}, {s1}, {t}, {t1}, [{n}]"))
    pair_singles = [("x0", "x1", "x2"), ("x6", "x9", "sp")]
    for base in ("rcwswpp", "rcwsswpp", "rcwclrp", "rcwsclrp", "rcwsetp", "rcwssetp"):
        for ar in ACQ_REL:
            for t1, t2, n in (pair_singles if ar == "" else pair_singles[:1]):
                out.append(("the-d128", f"{base}{ar} {t1}, {t2}, [{n}]"))
    return out


def lrcpc() -> list[tuple[str, str]]:
    """LDAPUR/STLUR (FEAT_LRCPC2) share the 0x19/0x59/0x99/0xd9 top bytes with MOPS and THE."""
    out = []
    forms = [
        ("stlurb", "w"), ("ldapurb", "w"), ("ldapursb", "x"), ("ldapursb", "w"),
        ("stlurh", "w"), ("ldapurh", "w"), ("ldapursh", "x"), ("ldapursh", "w"),
        ("stlur", "w"), ("ldapur", "w"), ("ldapursw", "x"),
        ("stlur", "x"), ("ldapur", "x"),
    ]
    for mnemonic, width in forms:
        for rt, rn, off in (("0", "x1", 0), ("7", "sp", -256), ("30", "x29", 255), ("12", "x3", -1)):
            reg = f"{width}{rt}"
            out.append(("lrcpc", f"{mnemonic} {reg}, [{rn}, #{off}]"))
    return out


def assemble(lines: list[str], workdir: pathlib.Path, name: str) -> list[tuple[int, str, str, str]]:
    source = workdir / f"{name}.s"
    obj = workdir / f"{name}.o"
    source.write_text("\n".join(lines) + "\n", encoding="utf-8")
    subprocess.run(["xcrun", "clang", "-c", "-arch", "arm64", f"-march={MARCH}", str(source), "-o", str(obj)],
                   check=True)
    dump = subprocess.run(["xcrun", "llvm-objdump", "-d", "--no-show-raw-insn", "--print-imm-hex",
                           f"--mattr={MATTR}", str(obj)], check=True, capture_output=True, text=True).stdout
    raw = subprocess.run(["xcrun", "llvm-objdump", "-d", f"--mattr={MATTR}", str(obj)],
                         check=True, capture_output=True, text=True).stdout
    words = {}
    for line in raw.splitlines():
        m = re.match(r"^\s*([0-9a-f]+):\s+([0-9a-f]{8})\s", line)
        if m:
            words[int(m.group(1), 16)] = m.group(2)
    rows = []
    for line in dump.splitlines():
        m = re.match(r"^\s*([0-9a-f]+):\s+(\S+)(?:\s+(.*))?$", line)
        if not m:
            continue
        address = int(m.group(1), 16)
        mnemonic = m.group(2)
        operands = (m.group(3) or "").strip()
        operands = re.sub(r"\s*<[^>]*>$", "", operands)
        rows.append((address, words[address], mnemonic, operands))
    return rows


def generate(workdir: pathlib.Path) -> tuple[str, str]:
    specs = pauth_lr() + mops() + the() + lrcpc()
    asm: list[str] = []
    expected: list[tuple[str, str]] = []  # (family, source) in emission order
    label = 0
    for family, source in specs:
        if family == "pauth-lr-label":
            mnemonic, words_back = source.split(":")
            label += 1
            asm.append(f"L{label}:")
            if int(words_back):
                asm.append(f"  .space {int(words_back) * 4}")
            asm.append(f"  {mnemonic} L{label}")
            expected.append(("pauth-lr", f"{mnemonic} <pc - {int(words_back) * 4:#x}>"))
        else:
            asm.append(f"  {source}")
            expected.append((family, source))
    rows = [r for r in assemble(asm, workdir, "vectors") if r[1] != "00000000"]
    if len(rows) != len(expected):
        raise SystemExit(f"ERROR: {len(expected)} sources but {len(rows)} disassembled instructions")
    vector_lines = ["# family\taddress\tword\tmnemonic\toperands\tsource",
                    f"# generated by Scripts/arm64_golden/generate_arm64_feature_vectors.py; "
                    f"clang -march={MARCH}; llvm-objdump --mattr={MATTR}"]
    for (family, source), (address, word, mnemonic, operands) in zip(expected, rows):
        if mnemonic in ("<unknown>", ".word", "udf"):
            raise SystemExit(f"ERROR: objdump did not decode {source!r}: {word} {mnemonic}")
        vector_lines.append(f"{family}\t{address:#x}\t{word}\t{mnemonic}\t{operands}\t{source}")

    # Boundary set: every single-bit flip of one representative per encoding group.
    reps: dict[tuple[str, str], str] = {}
    for (family, source), (_, word, mnemonic, _) in zip(expected, rows):
        key = (family, re.sub(r"(a|al|l)$", "", mnemonic) if family.startswith("the") else mnemonic[:5])
        reps.setdefault(key, word)
    flips = set()
    for word in reps.values():
        value = int(word, 16)
        flips.add(value)
        for bit in range(32):
            flips.add(value ^ (1 << bit))
    # Register-edge sweep: every combination of {0, 1, 2, 30, 31} in the three register
    # fields (bits 20:16, 9:5, 4:0) of one word per register-bearing group. This pins
    # objdump's aliasing / XZR / odd-pair rejections.
    edge = (0, 1, 2, 30, 31)
    for word in REGISTER_SWEEP_BASES:
        for a in edge:
            for b in edge:
                for c in edge:
                    flips.add((word & ~0x001f_03ff) | (a << 16) | (b << 5) | c)
    ordered = sorted(flips)
    inst_lines = [f"  .inst {w:#010x}" for w in ordered]
    brows = assemble(inst_lines, workdir, "boundary")
    if len(brows) != len(ordered):
        raise SystemExit("ERROR: boundary disassembly count mismatch")
    boundary_lines = ["# address\tword\tmnemonic\toperands",
                      f"# single-bit flips of {len(reps)} representatives + register-edge sweep; "
                      f"llvm-objdump --mattr={MATTR}; `<unknown>` = rejected by objdump"]
    for w, (address, word, mnemonic, operands) in zip(ordered, brows):
        assert int(word, 16) == w
        boundary_lines.append(f"{address:#x}\t{word}\t{mnemonic}\t{operands}")
    return "\n".join(vector_lines) + "\n", "\n".join(boundary_lines) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    with tempfile.TemporaryDirectory() as tmp:
        vectors, boundary = generate(pathlib.Path(tmp))
    targets = {OUT / "vectors.tsv": vectors, OUT / "boundary.tsv": boundary}
    if args.check:
        stale = [p for p, text in targets.items() if not p.exists() or p.read_text(encoding="utf-8") != text]
        for p in stale:
            print(f"STALE: {p.relative_to(ROOT)}", file=sys.stderr)
        return 1 if stale else 0
    OUT.mkdir(parents=True, exist_ok=True)
    for p, text in targets.items():
        p.write_text(text, encoding="utf-8")
        print(f"wrote {p.relative_to(ROOT)} ({text.count(chr(10)) - 2} rows)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
