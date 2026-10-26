# Decompiler oracles

Reusable checks for decompiler changes, including IR lifting and control-flow
structuring. Scripts are tracked; generated per-function data remains outside
the repository. Independent reference output can expose errors that a test
sharing implementation assumptions would miss.

## Files

| Script | What it does | Ground truth |
|---|---|---|
| `sweep.py` | Decompile the 4-binary corpus (`/bin/ls`, `/usr/bin/grep`, `/usr/bin/ssh`, `/bin/zsh`) with `MACSCOPE_REGIONTREE_DIAGNOSTICS=1`; write per-function `{address, pseudocode, fallback, fatal, gotos, unknowns}` + an aggregate histogram. | the MacScope build under test |
| `regen_baseline.sh` | Build (or take `--binary`) + sweep into an out-dir; **refuses degenerate data** (0 functions, or all-empty fallback = diagnostics not captured). Run on the pristine pre-merge tree for the "before" side. | — |
| `additivity.py` | For an **IR-lifting** change: `__unknown` count must DROP; zero scalar regressions (a new `__unknown` is allowed ONLY if SIMD or a pair-with-writeback honest refusal); no SIMD writeback lifted; coarse silent-fold screen. | two sweep dirs |
| `differential.py` | For a **structuring** change: unchanged-status functions byte-identical; flips are monotone (`unsupportedRegion → structured` only); statement multiset preserved (only scaffolding/`__compare`/`__branch` may be absorbed); goto count non-increasing. | two sweep dirs |

A change-specific oracle (e.g. IR-5's otool-grounded `writeback_oracle.py`, which closes the
blind spots the `__unknown` differential can't see) is built per-change and lives with that
change; the four scripts here are the reusable spine.

## Usage

```bash
# before (pristine main), after (candidate build) — the differential inputs:
Scripts/decompiler-oracles/regen_baseline.sh /tmp/before --binary <main-build>/MacScope
Scripts/decompiler-oracles/regen_baseline.sh /tmp/after  --binary <candidate-build>/MacScope

# IR-lifting change gate:
Scripts/decompiler-oracles/additivity.py  /tmp/before /tmp/after   # exit 0 = additive+faithful
# structuring change gate:
Scripts/decompiler-oracles/differential.py /tmp/before /tmp/after  # exit 0 = invariants hold
```

## Self-test discipline (do this before trusting any oracle)

An oracle is only as good as its own validation. Before using one to gate a merge:
- **Identity**: run it with the SAME dir as before and after. `differential.py` must report 0
  flips / 0 violations; `additivity.py` must fire `A1 __unknown did not drop` (identity is not
  additive) and nothing else. If identity doesn't behave, the oracle is miscalibrated.
- **Schema guard**: both differentials abort if a sweep dir lacks the enriched fields (a
  pre-enrichment dir would silently degenerate every comparison).
- **Stale-binary guard**: `regen_baseline.sh` refuses an all-empty-fallback sweep (the binary
  predates the diagnostics instrumentation, or the env var didn't take) — this caught a stale
  pre-IR-4 build during its own bring-up.
