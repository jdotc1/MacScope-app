#!/usr/bin/env python3
"""IR-5 writeback oracle — otool-grounded, site-anchored. Closes the additivity blind spots:
the ~520 pre-index sites are non-__unknown before AND after (multiset-invisible), and a
well-formed-but-wrong post-index lift keeps counts green. Ground truth = otool disassembly.

Gates:
  G1  UNTOUCHED-FUNCTION INVARIANT: any function containing ZERO writeback sites and ZERO
      added-mnemonic (ldursw/ldursb/ldpsw) sites must render BYTE-IDENTICAL. Catches
      state-threading / projection leakage into unrelated code.
  G2  SITE-ANCHORED DELTA CHECK: for each function F and signed delta D over F's scalar
      single-register writeback sites, the candidate text of F must contain at least
      baseline_count(term) + n_sites(F, D) occurrences of the rendered update term
      `[+-] 0xD`. Catches dropped updates, wrong direction, and width-scaled deltas.
      (Zero-delta sites are exempted and listed for hand-check.)
  G3  SIMD/PAIR FREEZE: per function, the count of __unknown lines whose operand text has a
      writeback shape AND a SIMD register or pair mnemonic must be unchanged. Catches an
      over-broad lift crossing the SIMD/pair scope line.
  G2b POST-INDEX VANISH: every scalar single-register post-index __unknown present in the
      baseline text must be ABSENT in the candidate (the lift actually happened).

Violations print as a triage list; gap-mapped sites (otool address falling between sweep
functions) can produce rare false positives — the driver hand-triages, target is 0 after triage.

Usage: writeback_oracle.py <baseline-dir> <candidate-dir>
"""
import json, os, re, subprocess, sys
from collections import Counter, defaultdict

BASE, CAND = sys.argv[1], sys.argv[2]
CORPUS = {"ls": "/bin/ls", "grep": "/usr/bin/grep", "ssh": "/usr/bin/ssh", "zsh": "/bin/zsh"}
PAIR = {"ldp", "stp", "ldpsw", "ldnp", "stnp"}
ADDED = ("ldursw", "ldursb", "ldpsw")

def disasm(path):
    out = subprocess.run(["otool", "-tv", "-arch", "arm64e", path], capture_output=True, text=True).stdout
    if not out.strip():
        out = subprocess.run(["otool", "-tv", path], capture_output=True, text=True).stdout
    return out

def parse_sites(text):
    """-> list of (addr:int, mnemonic, kind 'post'|'pre', scalar_single:bool, delta:int)"""
    sites = []
    for line in text.splitlines():
        parts = line.split("\t")
        if len(parts) < 3:
            continue
        addr_s, mn, ops = parts[0].strip(), parts[1].strip(), "\t".join(parts[2:])
        if not mn.startswith(("ld", "st")):
            continue
        try:
            addr = int(addr_s, 16)
        except ValueError:
            continue
        scalar_rt = bool(re.match(r"^\s*[wx]\d+", ops))
        single = mn not in PAIR
        m = re.search(r"\],\s*#(-?)(?:0x)?([0-9a-fA-F]+)", ops)
        if m:
            delta = int(m.group(2), 16 if "0x" in ops[m.start():m.end()] else 10)
            if m.group(1) == "-":
                delta = -delta
            sites.append((addr, mn, "post", scalar_rt and single, delta))
            continue
        if ops.rstrip().endswith("!"):
            m2 = re.search(r"\[\s*\w+\s*,\s*#(-?)(?:0x)?([0-9a-fA-F]+)\s*\]!", ops)
            delta = 0
            if m2:
                delta = int(m2.group(2), 16 if "0x" in ops[m2.start():m2.end()] else 10)
                if m2.group(1) == "-":
                    delta = -delta
            sites.append((addr, mn, "pre", scalar_rt and single, delta))
    return sites

def load(d, b):
    p = os.path.join(d, b + ".json")
    if not os.path.exists(p):
        return {}
    recs = json.load(open(p))
    return {int(r["address"], 16): r for r in recs}

def delta_term_count(text, delta):
    """Count rendered `+ 0xD` / `- 0xD` occurrences (printer renders immediates as 0x-hex).
    STRIP __unknown lines first: an un-lifted writeback's operand string carries the delta as
    `#-0xD`, which `[-]\\s*0xD` would spuriously match — so a NEGATIVE-delta site would count in
    the baseline __unknown, then vanish on lift while the render adds its own `- 0xD`, netting zero
    and false-flagging G2. Counting only NON-__unknown lines makes the +n increase real."""
    body = "\n".join(l for l in text.splitlines() if "__unknown(" not in l)
    sign = "-" if delta < 0 else "+"
    mag = abs(delta)
    pat = re.compile(r"[" + re.escape(sign) + r"]\s*0x%x\b" % mag)
    return len(pat.findall(body))

POSTUNK = re.compile(r'__unknown\("((?:ld|st)[a-z0-9]*)",\s*"([^"]*\],\s*#[^"]*)"\)')
WBUNK = re.compile(r'__unknown\("((?:ld|st)[a-z0-9]*)",\s*"([^"]*(?:\],\s*#|\]!)[^"]*)"\)')
ADDEDUNK = re.compile(r'__unknown\("(%s)"' % "|".join(ADDED))

def is_simd_ops(ops):
    return ("." in ops) or bool(re.search(r"\b[qvdshb]\d", ops))

viol = []
zero_delta_flags = []
g1_checked = g1_ok = g2_sites = g2_ok = 0

for b, path in CORPUS.items():
    A, C = load(BASE, b), load(CAND, b)
    if not A or not C:
        viol.append((b, "-", "missing sweep json"))
        continue
    starts = sorted(A)
    sites = parse_sites(disasm(path))
    # map site addr -> containing function start (greatest start <= addr, bounded by next)
    by_fn = defaultdict(list)
    import bisect
    for s in sites:
        i = bisect.bisect_right(starts, s[0]) - 1
        if i >= 0:
            by_fn[starts[i]].append(s)

    for fn, ar in A.items():
        cr = C.get(fn)
        if cr is None:
            viol.append((b, hex(fn), "function missing in candidate"))
            continue
        at, ct = ar["pseudocode"], cr["pseudocode"]
        fn_sites = by_fn.get(fn, [])
        has_added = any(m in at for m in ADDED) or bool(ADDEDUNK.search(at))
        # G1
        if not fn_sites and not has_added:
            g1_checked += 1
            if at == ct:
                g1_ok += 1
            else:
                viol.append((b, hex(fn), "G1 no writeback/added-mnemonic site but text CHANGED"))
            continue
        # G3 — a SIMD/pair writeback __unknown must never be LOST (would mean it was wrongly
        # lifted). NEW pair-writeback __unknowns ARE allowed: converting a silently-wrong non-stack
        # pair writeback into an honest __unknown is the intended IR-5 fix. So flag only REMOVALS,
        # plus any NEW *SIMD* (non-pair) writeback __unknown (a SIMD form should never appear anew).
        a_simd = Counter(m.group(0) for m in WBUNK.finditer(at)
                         if m.group(1) in PAIR or is_simd_ops(m.group(2)))
        c_simd = Counter(m.group(0) for m in WBUNK.finditer(ct)
                         if m.group(1) in PAIR or is_simd_ops(m.group(2)))
        lost = a_simd - c_simd
        if lost:
            viol.append((b, hex(fn), f"G3 SIMD/pair writeback __unknown LOST (wrongly lifted?): {list(lost.keys())[:2]}"))
        gained_simd = Counter(k for k in (c_simd - a_simd)
                              for mm in [re.search(r'__unknown\("([a-z0-9]+)",\s*"([^"]*)"', k)]
                              if mm and mm.group(1) not in PAIR and is_simd_ops(mm.group(2)))
        if gained_simd:
            viol.append((b, hex(fn), f"G3 NEW SIMD writeback __unknown appeared: {list(gained_simd.keys())[:2]}"))
        # G2 / G2b — scalar single-register sites only
        scalar_sites = [s for s in fn_sites if s[3]]
        deltas = Counter(s[4] for s in scalar_sites)
        for delta, n in deltas.items():
            if delta == 0:
                zero_delta_flags.append((b, hex(fn), n))
                continue
            g2_sites += n
            base_n = delta_term_count(at, delta)
            cand_n = delta_term_count(ct, delta)
            if cand_n >= base_n + n:
                g2_ok += n
            else:
                viol.append((b, hex(fn), f"G2 delta {'+' if delta>0 else ''}{delta:#x}: need >= {base_n}+{n} rendered update terms, found {cand_n}"))
        # G2b
        for m in POSTUNK.finditer(at):
            if (m.group(1) not in PAIR) and not is_simd_ops(m.group(2)):
                if m.group(0) in ct:
                    viol.append((b, hex(fn), f"G2b post-index __unknown NOT lifted: {m.group(1)} \"{m.group(2)}\""))

print(f"G1 untouched-function invariant: {g1_ok}/{g1_checked} byte-identical")
print(f"G2 site-anchored delta terms:    {g2_ok}/{g2_sites} sites accounted")
if zero_delta_flags:
    print(f"zero-delta sites (hand-check): {sum(n for _,_,n in zero_delta_flags)} across {len(zero_delta_flags)} fns")
print(f"\nviolations: {len(viol)} (triage list, target 0)")
for v in viol[:40]:
    print("  VIOLATION:", v)
sys.exit(0 if not viol else 2)
