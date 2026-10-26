#!/usr/bin/env python3
"""Fail when hard-coded styling grows outside MacScope/DesignSystem.

Runs style_audit.py over MacScope/, counts hard-coded hits (literal colors, font sizes,
paddings, spacings, radii, frames, materials) per file and category, and compares them with
style_baseline.json. Existing debt is allowed; any increase fails with the new sites listed.
Lower the baseline after a burn-down with --update.

Usage (from the repository root):
    python3 Scripts/design/style_ratchet.py            # check
    python3 Scripts/design/style_ratchet.py --update   # accept the current counts
"""
from __future__ import annotations

import argparse
import collections
import json
import pathlib
import subprocess
import sys
import tempfile

HERE = pathlib.Path(__file__).resolve().parent
REPO = HERE.parent.parent
SOURCE_ROOT = REPO / "MacScope"
BASELINE = HERE / "style_baseline.json"


def current_hits() -> list[dict]:
    with tempfile.TemporaryDirectory() as tmp:
        out = pathlib.Path(tmp) / "audit.json"
        subprocess.run(
            [sys.executable, str(HERE / "style_audit.py"), str(SOURCE_ROOT), "--json", str(out)],
            check=True,
            stdout=subprocess.DEVNULL,
        )
        hits = json.loads(out.read_text())["hits"]
    return [h for h in hits if h["hard"] and not h["file"].startswith("DesignSystem/")]


def counts(hits: list[dict]) -> dict[str, dict[str, int]]:
    table: dict[str, collections.Counter] = collections.defaultdict(collections.Counter)
    for h in hits:
        table[h["file"]][h["cat"]] += 1
    return {f: dict(sorted(c.items())) for f, c in sorted(table.items())}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--update", action="store_true", help="write the current counts as the new baseline")
    args = parser.parse_args()

    hits = current_hits()
    now = counts(hits)
    if args.update:
        BASELINE.write_text(json.dumps(now, indent=1, sort_keys=True) + "\n")
        print(f"style baseline updated: {sum(sum(c.values()) for c in now.values())} hard-coded sites in {len(now)} files")
        return 0

    baseline = json.loads(BASELINE.read_text()) if BASELINE.exists() else {}
    grown = []
    for file, cats in now.items():
        for cat, n in cats.items():
            allowed = baseline.get(file, {}).get(cat, 0)
            if n > allowed:
                grown.append((file, cat, allowed, n))
    shrunk = sum(
        max(0, allowed - now.get(file, {}).get(cat, 0))
        for file, cats in baseline.items() for cat, allowed in cats.items()
    )
    if grown:
        print("Hard-coded styling grew outside DesignSystem/. Use Lumen tokens (Lumen.Space, Lumen.Radius, Lumen.Font) and palette colors instead:")
        for file, cat, allowed, n in grown:
            print(f"  {file}: {cat} {allowed} -> {n}")
            for h in hits:
                if h["file"] == file and h["cat"] == cat:
                    print(f"      line {h['line']}: {h['code'].strip()[:110]}")
        return 1
    note = f"; {shrunk} fewer than the baseline, run with --update to lock that in" if shrunk else ""
    print(f"style ratchet ok: {sum(sum(c.values()) for c in now.values())} hard-coded sites, none new{note}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
