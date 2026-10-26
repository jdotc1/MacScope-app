#!/usr/bin/env python3
"""Structuring differential oracle: compare two enriched sweep dirs (baseline vs candidate).

Invariants enforced (the driver's tamper-proof gate):
  I1  Any function whose fallback status is UNCHANGED must have byte-identical pseudocode
      (unless --allow-text-diff-for is given a fatal-veto name whose text may legitimately
      move, e.g. an IR-lifting handoff; structuring handoffs use the strict form).
  I2  Flipped functions must go unsupportedRegion -> structured ONLY (monotone; no
      structured -> unsupportedRegion, no new unstructurableCFG).
  I3  Statement multiset preserved on flipped functions: the multiset of NON-SCAFFOLDING
      lines (statements) must be identical. Scaffolding = structure the flip legitimately
      changes: goto lines, bare labels, brace-only lines, if/else/while/do headers,
      break/continue, and blank/comment-only lines. __compare/__branch* lines are treated
      as scaffolding ONLY when they disappear (absorbed into structure), never when added.
  I4  goto count must not increase on any function; aggregate goto count must decrease
      or stay equal.
  I5  __unknown count per function must not increase.

Usage: differential.py <baseline-dir> <candidate-dir> [--verbose]
Exit 0 = all invariants hold; 2 = violation (details printed).
"""
import json, os, re, sys
from collections import Counter

BASE, CAND = sys.argv[1], sys.argv[2]
VERBOSE = "--verbose" in sys.argv
BINARIES = ["ls", "grep", "ssh", "zsh"]

GOTO = re.compile(r'^\s*goto 0x[0-9a-fA-F]+;')
LABEL = re.compile(r'^\s*0x[0-9a-fA-F]+:\s*(//.*)?$')
HEADER = re.compile(r'^\s*(\}\s*)?(if\s*\(|else\b|while\s*\(|do\b|for\s*\(|switch\s*\()')
BRACE_ONLY = re.compile(r'^\s*[{}]+\s*(//.*)?$')
BREAKCONT = re.compile(r'^\s*(break|continue);')
COMMENT_ONLY = re.compile(r'^\s*(//.*)?$')
ABSORBABLE = re.compile(r'^\s*(__compare\(|__branch(_[a-z]+)?\()')

def normalize(line):
    # strip trailing comments for comparison robustness? NO — comments carry addresses;
    # keep the full line but strip leading/trailing whitespace (indent changes with nesting).
    return line.strip()

def is_scaffolding(line):
    s = line.strip()
    return bool(GOTO.match(s) or LABEL.match(s) or HEADER.match(s) or BRACE_ONLY.match(s)
                or BREAKCONT.match(s) or COMMENT_ONLY.match(s))

def statements(pc):
    out = Counter()
    for line in pc.splitlines():
        if is_scaffolding(line):
            continue
        out[normalize(line)] += 1
    return out

def load(d, b):
    p = os.path.join(d, b + ".json")
    if not os.path.exists(p):
        return {}
    recs = json.load(open(p))
    # Schema guard: both sweeps MUST be enriched (fallback/gotos/unknowns present).
    # A pre-enrichment sweep dir would silently degenerate every comparison.
    for r in recs[:1]:
        for k in ("fallback", "gotos", "unknowns"):
            if k not in r:
                sys.exit(f"FATAL: {p} lacks '{k}' — re-run sweep.py (enriched) for this dir")
    return {r["address"]: r for r in recs}

violations = []
flips = []
agg_goto_base = agg_goto_cand = 0
for b in BINARIES:
    A, C = load(BASE, b), load(CAND, b)
    for addr, ar in A.items():
        cr = C.get(addr)
        if cr is None:
            violations.append((b, addr, "function MISSING in candidate sweep"))
            continue
        agg_goto_base += ar.get("gotos", 0)
        agg_goto_cand += cr.get("gotos", 0)
        afb, cfb = ar.get("fallback", ""), cr.get("fallback", "")
        # I5
        if cr.get("unknowns", 0) > ar.get("unknowns", 0):
            violations.append((b, addr, f"I5 __unknown increased {ar.get('unknowns')} -> {cr.get('unknowns')}"))
        # I4 per-function
        if cr.get("gotos", 0) > ar.get("gotos", 0):
            violations.append((b, addr, f"I4 goto increased {ar.get('gotos')} -> {cr.get('gotos')}"))
        if afb == cfb:
            if ar["pseudocode"] != cr["pseudocode"]:
                violations.append((b, addr, f"I1 unchanged-status ({afb}) but text differs"))
            continue
        # status changed
        if not (afb == "unsupportedRegion" and cfb == "structured"):
            violations.append((b, addr, f"I2 non-monotone flip {afb} -> {cfb}"))
            continue
        flips.append((b, addr))
        sa, sc = statements(ar["pseudocode"]), statements(cr["pseudocode"])
        if sa != sc:
            gained = sc - sa
            lost = sa - sc
            # Absorbed __compare/__branch lines may vanish; nothing may be GAINED,
            # and nothing non-absorbable may be lost.
            bad_gain = {k: v for k, v in gained.items()}
            bad_loss = {k: v for k, v in lost.items() if not ABSORBABLE.match(k)}
            if bad_gain or bad_loss:
                detail = f"I3 statement multiset: +{list(bad_gain.items())[:3]} -{list(bad_loss.items())[:3]}"
                violations.append((b, addr, detail))
            elif VERBOSE:
                print(f"  [absorbed-ok] {b} {addr}: -{sum(lost.values())} compare/branch lines")

print(f"flips (unsupportedRegion -> structured): {len(flips)}")
for b, addr in flips[:40]:
    print(f"   [{b}] {addr}")
print(f"aggregate gotos: {agg_goto_base} -> {agg_goto_cand} (delta {agg_goto_cand - agg_goto_base})")
print(f"violations: {len(violations)}")
for v in violations[:30]:
    print("  VIOLATION:", v)
sys.exit(0 if not violations else 2)
