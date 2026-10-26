#!/usr/bin/env python3
"""Generate the MS-23 reserved-encoding boundary vectors (ARM64ReservedEncodingGoldenTests).

Ground truth is the local Apple toolchain only, in generic (ELF) syntax: the words are emitted with
`.inst`, assembled by `xcrun clang -c -target aarch64-none-elf` and disassembled by
`xcrun llvm-objdump -d --print-imm-hex --mattr=<differential_sweep.MATTR>`. Nothing is hand-decoded.

The word list is small and fixed (no random sweep): for each encoding class
it holds example words plus a few valid seed encodings and their single-bit flips over the reserved fields
that class checks. Reserved neighbours must decode as `unknown`; valid neighbours must match
objdump's text.

Output: MacScope/Tests/CoreTests/GoldenFixtures/arm64-reserved-vectors/vectors.tsv
          class  address  word  objdump-text        (`<unknown>` where objdump rejects the word)

usage: Scripts/arm64_golden/generate_arm64_reserved_vectors.py [--check]
"""
from __future__ import annotations

import argparse
import pathlib
import sys
import tempfile

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import differential_sweep as ds  # noqa: E402  (MATTR, oracle chunk, normalisation)

ROOT = pathlib.Path(__file__).resolve().parents[2]
OUT = ROOT / "MacScope/Tests/CoreTests/GoldenFixtures/arm64-reserved-vectors/vectors.tsv"

# (class, ledger example words, seed words, bits to flip in each seed)
CLASSES: list[tuple[str, list[int], list[int], list[int]]] = [
    ("c01-carry-vs-loadstore",
     [0x3BA58780, 0x3ADC9689, 0xBB8BEBF1, 0xFA0A0343, 0x3A1C0264, 0x7A0A0329, 0xBA1F842F, 0x3A000400,
      0x3A00080D, 0x3A00480D, 0x1AC03000],
     [0x1A020020, 0x9A020020, 0x3A020020, 0xBA020020, 0x5A020020, 0xDA020020, 0x7A020020, 0xFA020020,
      0xDA0203E0, 0x7A0203E0],
     [25, 10, 11, 15, 21]),
    ("c02-shift-sf0",
     [0x4ADDE52C, 0x4AD991FF, 0x0A55DC94],
     [0x4A827C20, 0x0B427C20, 0x2A0203E0, 0x6B027C3F],
     [15, 31]),
    ("c03-simd-structure",
     [0x8CCA4980, 0x8DCE42C8, 0x4C2BAAD8],
     [0x4C407000, 0x4CDF7000, 0x4CC2A000, 0x0D400000, 0x4DDF0400, 0x0D40C000],
     [31, 21, 16, 20, 23]),
    ("c04-bitfield",
     [0x933D0452, 0xD31636FE, 0x33178DBD],
     [0x93407C20, 0x53001C20, 0x33000C20, 0xD3410420, 0x13001C20],
     [22, 31, 21, 15, 30]),
    ("c05-extract",
     [0xB3D4ECED, 0x53B3F261, 0x93E3CBD6],
     [0x93C20C20, 0x13820C20, 0x93C10C20],
     [22, 31, 29, 30, 21, 15]),
    ("c06-three-source",
     [0x1B3E1A63, 0xDBA63F32, 0xDBAF01F3],
     [0x1B020C20, 0x9B220C20, 0x9B427C20, 0x9BA20C20, 0x9BC27C20, 0x9B028C20],
     [29, 30, 31, 23]),
    ("c07-ccmp",
     [0xFA4DF6ED, 0xBA5492D6, 0x3A5B47C5],
     [0x7A420020, 0xFA420820, 0x3A420020],
     [10, 4, 31]),
    ("c08-addsub-shift-ror",
     [0x8BC0E3AB, 0xCBD86F84, 0xEBCEE69E],
     [0x8B020C20, 0xCB420C20, 0xEB820C20],
     [22, 23]),
    ("c09-movewide",
     [0x72DC82D8, 0x12F12F3C, 0x52F5A975, 0x92C00020, 0x92F2A6A0],
     [0x12800020, 0x52A00020, 0x72A00020, 0x92A00020, 0xD2E00020, 0xF2C00020],
     [22, 21, 31]),
    ("c10-extended-register",
     [0xAB3654B5, 0x4B3B9C14, 0x2B217FD0, 0x0B235294, 0x2B3BED00],
     [0x8B225020, 0x0B225020, 0x8B2263E0, 0x8B22603F, 0x0B2243E0, 0xAB2263E0, 0x2B22603F],
     [10, 11, 12, 13, 14, 31]),
    ("c11-exception",
     [0xD414B97F, 0xD41A5CA9, 0xD45BBD30],
     [0xD4000001, 0xD4000002, 0xD4000003, 0xD4200000, 0xD4400000],
     [2, 3, 4]),
    ("c12-c15-scalar-fp",
     [0x9E7F661C, 0x9E222280, 0x9E6C4629, 0x1E66D16B, 0x1E36F14F, 0x1E7C6169],
     [0x1E222020, 0x1E622028, 0x1E220420, 0x1E201000, 0x1E621C20, 0x1E220C20, 0x1E224020],
     [31, 23, 22, 5, 9, 14, 15, 0, 2]),
    ("c13-pair",
     [0x6877125F, 0x687F83D7, 0x687D43B9],
     [0x29400420, 0x69400420, 0x68C00420, 0x28400420, 0x6D400420],
     [30, 31, 23, 24]),
    ("c14-casp",
     [0x086A8042, 0x087C0DC6, 0x08660430],
     [0x08207C22, 0x48207C22, 0x08607C22],
     [10, 14, 16, 0]),
    ("c16-simd-three-same-size",
     [0x2E699F7F, 0x2EF59E11, 0x2EF69F15, 0x4EE39F1A],
     [0x2E229C20, 0x0E229C20, 0x4EA29C20, 0x4EE28420, 0x0E626C20],
     [22, 23, 30]),
    ("bug-fp-vector-compare",
     [0x2E3DE663, 0x6E75EE3F, 0x6EFDEFEC],
     [0x0E22E420, 0x4E62E420],
     [29, 23, 11]),
    ("bug-lse-store-alias",
     [0x78B3137F],
     [0xB822103F, 0xF822303F, 0x3822003F],
     [23, 22]),
    ("bug-barrier-op1",
     [0xD504339F],
     [0xD503339F, 0xD50339BF, 0xD5033FDF],
     [16, 17, 18]),
    # MS-23 remainder (ledger residual classes and the op1 checks).
    ("r-simd-scalar-shift-immh",
     [0x5F3D166A],
     [0x5F7F0420, 0x5F7F1420, 0x5F415420, 0x5F097420, 0x7F097420, 0x7F096420],
     [22, 21, 20, 19]),
    ("r-fp-fixed-point-sf0",
     [0x1ED801F7],
     [0x1E18FC20, 0x1E02FC20, 0x1E03FC20, 0x1E19FC20, 0x9E58FC20, 0x9E438020],
     [15, 31, 14]),
    ("r-pac-zero-modifier-rn",
     [0xDAC12C00],
     [0xDAC123E0, 0xDAC12FE0, 0xDAC137E0, 0xDAC13FE0, 0xDAC143E0, 0xDAC147E0],
     [5, 9]),
    ("r-hint-op1",
     [0xD500201F],
     [0xD503201F, 0xD503233F, 0xD503245F, 0xD503221F, 0xD503229F, 0xD503251F, 0xD503211F, 0xD50320DF],
     [16, 17, 18]),
    ("r-msr-immediate-op1",
     [],
     [0xD50341DF, 0xD50040BF, 0xD500419F, 0xD503405F, 0xD503409F, 0xD500407F, 0xD501401F, 0xD501421F,
      0xD503477F, 0xD503427F, 0xD50341FF],
     [16, 17, 18, 5, 6, 7]),
    ("r-dcps",
     [],
     [0xD4A00001, 0xD4A00002, 0xD4A00003, 0xD4A00021],
     [0, 1, 2, 22]),
]


def words_by_class() -> list[tuple[str, int]]:
    rows: list[tuple[str, int]] = []
    seen: set[int] = set()
    for name, examples, seeds, bits in CLASSES:
        candidates = list(examples)
        for seed in seeds:
            candidates.append(seed)
            candidates.extend(seed ^ (1 << bit) for bit in bits)
        for word in candidates:
            if word not in seen:
                seen.add(word)
                rows.append((name, word))
    return rows


def render() -> str:
    rows = words_by_class()
    with tempfile.TemporaryDirectory() as tmp:
        texts = ds.llvm_chunk(0, [w for _, w in rows], 0, pathlib.Path(tmp))
    lines = [
        "# class\taddress\tword\tobjdump",
        "# generated by Scripts/arm64_golden/generate_arm64_reserved_vectors.py; .inst -> xcrun clang -c "
        "-target aarch64-none-elf; xcrun llvm-objdump -d --print-imm-hex --mattr=<differential_sweep.MATTR>; "
        "`<unknown>` = rejected by objdump",
    ]
    for index, ((name, word), text) in enumerate(zip(rows, texts)):
        text = ds.normalize(text)
        if not ds.llvm_decodes(text):
            text = "<unknown>"
        lines.append(f"{name}\t{4 * index:#x}\t{word:08x}\t{text}")
    return "\n".join(lines) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    text = render()
    if args.check:
        if OUT.read_text(encoding="utf-8") != text:
            print(f"{OUT} is stale; rerun without --check", file=sys.stderr)
            return 1
        return 0
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(text, encoding="utf-8")
    print(f"wrote {len(text.splitlines()) - 2} rows to {OUT.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
