#!/usr/bin/env python3
"""Run the vendored sleigh-lift over the decoder lane's ARM64 golden vectors.

Offline.  Decodes every word of ``vectors.tsv`` and ``boundary.tsv`` with an
explicit AArch64 ``.sla`` and reports, per row, the SLEIGH text next to the
``llvm-objdump`` oracle text.  ``--json`` emits the per-row records so two
specifications (for example the upstream and the MacScope-patched ``.sla``)
can be diffed row by row; ``--summary`` prints the defect counts used by WP0.
"""

from __future__ import annotations

import argparse
import concurrent.futures
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
VECTOR_ROOT = ROOT / "MacScope/Tests/CoreTests/GoldenFixtures/arm64-feature-vectors"
SLEIGH_LIFT = ROOT / "ThirdParty/SleighNative/package/bin/sleigh-lift"
LANGUAGE_RELATIVE = Path("Ghidra/Processors/AARCH64/data/languages")
SLA_NAME = "AARCH64_AppleSilicon.sla"


def load_rows() -> list[dict[str, str]]:
    rows: list[dict[str, str]] = []
    for line in (VECTOR_ROOT / "vectors.tsv").read_text(encoding="utf-8").splitlines():
        if line.startswith("#") or not line.strip():
            continue
        family, address, word, mnemonic, operands, _source = line.split("\t")
        rows.append({"corpus": "vectors", "family": family, "address": address, "word": word,
                     "mnemonic": mnemonic, "operands": operands})
    for line in (VECTOR_ROOT / "boundary.tsv").read_text(encoding="utf-8").splitlines():
        if line.startswith("#") or not line.strip():
            continue
        address, word, mnemonic, operands = (line.split("\t") + [""])[:4]
        rows.append({"corpus": "boundary", "family": "boundary", "address": address, "word": word,
                     "mnemonic": mnemonic, "operands": operands})
    return rows


def spec_root_for(sla: Path, pspec: Path, scratch: Path) -> Path:
    """sleigh-lift resolves a .sla by name below a Ghidra-shaped spec root."""
    languages = scratch / "specfiles" / LANGUAGE_RELATIVE
    languages.mkdir(parents=True)
    shutil.copyfile(sla, languages / SLA_NAME)
    shutil.copyfile(pspec, languages / "AARCH64.pspec")
    return scratch / "specfiles"


def decode(word: str, spec_root: Path, pspec: Path, action: str, address: str = "0x0") -> str:
    little_endian = bytes.fromhex(word)[::-1].hex()
    completed = subprocess.run(
        # The row address matters for PC-relative operands (PAuth_LR <label> forms); -a is decimal.
        [str(SLEIGH_LIFT), action, SLA_NAME, little_endian, "-a", str(int(address, 16)), "-p", str(spec_root), "-s", str(pspec)],
        capture_output=True, text=True, check=False, timeout=60,
    )
    output = (completed.stdout + completed.stderr).strip()
    if "Unable to resolve constructor" in output or "BadDataError" in output:
        return "<undecodable>"
    if action == "disassemble":
        return re.sub(r"^0x[0-9a-f]+:\s*", "", output)
    return output


def normalize(text: str) -> str:
    text = re.sub(r"\s+", " ", text.strip().lower())
    text = re.sub(r"\s*,\s*", ", ", text)
    return text


def run(sla: Path, pspec: Path, *, pcode: bool, jobs: int) -> list[dict[str, str]]:
    rows = load_rows()
    with tempfile.TemporaryDirectory() as directory:
        spec_root = spec_root_for(sla, pspec, Path(directory))
        local_pspec = spec_root / LANGUAGE_RELATIVE / "AARCH64.pspec"
        with concurrent.futures.ThreadPoolExecutor(max_workers=jobs) as pool:
            texts = list(pool.map(lambda r: decode(r["word"], spec_root, local_pspec, "disassemble", r["address"]), rows))
            codes = (list(pool.map(lambda r: decode(r["word"], spec_root, local_pspec, "pcode", r["address"]), rows))
                     if pcode else [""] * len(rows))
    for row, text, code in zip(rows, texts, codes):
        row["sleigh"] = text
        row["pcode"] = code
        oracle = normalize(f"{row['mnemonic']} {row['operands']}")
        row["match"] = "yes" if normalize(text) == oracle else "no"
    return rows


def is_mops_mnemonic(mnemonic: str) -> bool:
    return bool(re.fullmatch(r"(cpyf?|setg?)[pme]\w*", mnemonic))


def summary(rows: list[dict[str, str]]) -> dict[str, int]:
    counts: dict[str, int] = {}

    def bump(key: str) -> None:
        counts[key] = counts.get(key, 0) + 1

    for row in rows:
        sleigh = row["sleigh"]
        mnemonic = sleigh.split(" ", 1)[0]
        oracle = row["mnemonic"]
        if row["corpus"] == "vectors":
            bump(f"vectors.{row['family']}.rows")
            if sleigh == "<undecodable>":
                bump(f"vectors.{row['family']}.undecodable")
            elif row["match"] != "yes":
                bump(f"vectors.{row['family']}.mismatch")
        if sleigh != "<undecodable>":
            if re.fullmatch(r"cpyf?[pme]\w*wt\w*", oracle) is None and re.fullmatch(r"cpyf?[pme]\w*wt\w*", mnemonic):
                bump("defect1.false_wt_decodes")
            if re.fullmatch(r"set[pme]{2}\w*", mnemonic) and not mnemonic.startswith("setg"):
                bump("defect2.setp_prefixed_mnemonic")
            if oracle != "bti" and mnemonic == "bti" and int(row["word"], 16) & 0x20:
                bump("defect3.bti_overaccept")
            if oracle == "<unknown>" and is_mops_mnemonic(mnemonic):
                bump("defect4.mops_overaccept")
        elif re.fullmatch(r"cpyf?[pme]\w*wt\w*", oracle):
            bump("defect1.wt_undecodable")
        if oracle == "pacm" and mnemonic != "pacm":
            bump("defect3.pacm_misdecoded")
    return dict(sorted(counts.items()))


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--sla", type=Path, required=True)
    parser.add_argument("--pspec", type=Path, required=True)
    parser.add_argument("--pcode", action="store_true")
    parser.add_argument("--jobs", type=int, default=os.cpu_count() or 4)
    parser.add_argument("--json", type=Path)
    arguments = parser.parse_args()
    rows = run(arguments.sla.resolve(), arguments.pspec.resolve(), pcode=arguments.pcode, jobs=arguments.jobs)
    if arguments.json:
        arguments.json.write_text(json.dumps(rows, indent=1) + "\n", encoding="utf-8")
    print(json.dumps(summary(rows), indent=1))
    return 0


if __name__ == "__main__":
    sys.exit(main())
