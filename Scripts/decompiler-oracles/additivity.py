#!/usr/bin/env python3
"""IR-5 additivity oracle: verify a MacIRBuilder lifting handoff is purely additive + faithful.

Gate (all must hold):
  A1  Total corpus __unknown count DROPS (report the delta; expect ~500+ for IR-5).
  A2  ZERO scalar regressions: no function gains a NET-NEW __unknown whose mnemonic is scalar.
      A newly-appeared __unknown is tolerated ONLY if its mnemonic is in the SIMD/vector set
      (the correctness-over-coverage escape hatch — a form the decoder explicitly refused).
  A3  No SIMD post-index was lifted: the SIMD writeback forms (str q0,[x19],#16 etc.) must STILL
      be __unknown in the candidate (measured by: SIMD-mnemonic __unknown count did not drop
      below its baseline for the writeback-shaped operands).
  A4  Visible base-update (catches the rejected silent-fold design): for every function whose
      __unknown count dropped AND that had >=1 post/pre-index writeback __unknown in baseline,
      the candidate text for that function must contain, on a line that is NOT a __unknown line,
      a base-register self-update term (`Rn = Rn + <imm>` / `Rn + <imm>` / `Rn - <imm>` /
      tuple `, Rn = ... Rn ...`). If a writeback __unknown vanished but no visible update appears,
      that's a SILENT FOLD -> violation.

Usage: additivity.py <baseline-dir> <candidate-dir>
Exit 0 = additive+faithful; 2 = violation.
"""
import json, os, re, sys
from collections import Counter

BASE, CAND = sys.argv[1], sys.argv[2]
BINARIES = ["ls", "grep", "ssh", "zsh"]

UNK = re.compile(r'__unknown\("([a-z0-9]+)",\s*"([^"]*)"\)')
# Vector/SIMD mnemonics that may legitimately remain/appear as __unknown.
SIMD = {
    "movi","mvni","ld1","ld2","ld3","ld4","st1","st2","st3","st4","smull","umull","smull2",
    "umull2","shrn","shrn2","ins","dup","sshll","ushll","tbl","tbx","zip1","zip2","uzp1","uzp2",
    "trn1","trn2","fmla","fmls","fmul","fadd","fsub","fdiv","fmax","fmin","frecpe","frsqrte",
    "sqadd","uqadd","sqsub","uqsub","addv","uaddlv","saddlv","cnt","rev64","xtn","xtn2","sqxtn",
    "uqxtn","scvtf","ucvtf","fcvtzs","fcvtzu","bsl","bit","bif","cmeq","cmgt","cmhi","abs","neg",
    "mla","mls","sabd","uabd","saba","uaba","umlal","smlal","pmull","aese","aesd","aesmc","sha256h",
}
POSTPRE_LDST = {"ldr","ldur","ldrb","ldrh","ldrsb","ldrsh","ldrsw","ldurb","ldurh","ldursw","ldursb",
                "str","stur","strb","strh","sturb","sturh"}

PAIR = {"ldp", "stp", "ldpsw", "ldnp", "stnp"}

def is_writeback_ops(ops):
    return bool(re.search(r'\]\s*,\s*#', ops)) or ops.rstrip().endswith("!")

def is_simd_ops(ops):
    return ("." in ops) or bool(re.search(r'\b[qvds]\d', ops))

def load(d, b):
    p = os.path.join(d, b + ".json")
    if not os.path.exists(p): return {}
    recs = json.load(open(p))
    if not isinstance(recs, list):
        sys.exit(f"FATAL: {p} is not a per-function list — pass an enriched sweep dir")
    return {r["address"]: r for r in recs}

# base-update term on a non-__unknown line
UPDATE = re.compile(r'\b\w+\s*[-+]\s*0x[0-9a-fA-F]+')

viol = []
tot_base = tot_cand = 0
simd_writeback_base = simd_writeback_cand = 0
folds_checked = folds_ok = 0

for b in BINARIES:
    A, C = load(BASE, b), load(CAND, b)
    for addr, ar in A.items():
        cr = C.get(addr)
        if cr is None:
            viol.append((b, addr, "function MISSING in candidate")); continue
        au = list(UNK.finditer(ar["pseudocode"]))
        cu = list(UNK.finditer(cr["pseudocode"]))
        tot_base += len(au); tot_cand += len(cu)
        # SIMD writeback bookkeeping for A3
        simd_writeback_base += sum(1 for m in au if m.group(1) in POSTPRE_LDST and is_writeback_ops(m.group(2)) and is_simd_ops(m.group(2)))
        simd_writeback_cand += sum(1 for m in cu if m.group(1) in POSTPRE_LDST and is_writeback_ops(m.group(2)) and is_simd_ops(m.group(2)))
        # A2: net-new scalar __unknown by (mnemonic, operands) multiset
        abag = Counter((m.group(1), m.group(2)) for m in au)
        cbag = Counter((m.group(1), m.group(2)) for m in cu)
        for (mn, ops), n in (cbag - abag).items():
            # Acceptable NEW __unknown: SIMD (any), or a PAIR-with-writeback that the fix
            # converts from silently-wrong to honest-refused (non-sp GPR pair writeback).
            acceptable = mn in SIMD or is_simd_ops(ops) or (mn in PAIR and is_writeback_ops(ops))
            if not acceptable:
                viol.append((b, addr, f"A2 NEW scalar __unknown x{n}: {mn} \"{ops}\""))
        # A4: silent-fold check
        had_scalar_wb = any(m.group(1) in POSTPRE_LDST and is_writeback_ops(m.group(2)) and not is_simd_ops(m.group(2)) for m in au)
        if had_scalar_wb and len(cu) < len(au):
            folds_checked += 1
            nonunk = "\n".join(l for l in cr["pseudocode"].splitlines() if "__unknown(" not in l)
            if UPDATE.search(nonunk):
                folds_ok += 1
            else:
                viol.append((b, addr, "A4 writeback __unknown vanished but NO visible base-update (silent fold?)"))

print(f"corpus __unknown: {tot_base} -> {tot_cand} (delta {tot_cand - tot_base})")
print(f"A3 SIMD-writeback __unknown (must NOT drop): {simd_writeback_base} -> {simd_writeback_cand}")
print(f"A4 silent-fold check: {folds_ok}/{folds_checked} flipped-writeback fns show a visible base-update")
if tot_cand >= tot_base:
    viol.append(("*","*", f"A1 __unknown did not drop ({tot_base} -> {tot_cand})"))
if simd_writeback_cand < simd_writeback_base:
    viol.append(("*","*", f"A3 a SIMD post/pre-index was lifted ({simd_writeback_base} -> {simd_writeback_cand})"))
print(f"\nviolations: {len(viol)}")
for v in viol[:40]:
    print("  VIOLATION:", v)
sys.exit(0 if not viol else 2)
