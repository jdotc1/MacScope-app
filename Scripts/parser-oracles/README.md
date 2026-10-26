# Parser oracles (RX-03)

Ground truth for MacScope's Mach-O, dyld shared cache and PE parsers. One command runs the
independent parser engines over curated specimens and freezes their answers as normalized JSON
goldens. MS-14 (PE string budgets), MS-15 (export from captured bytes), MS-16 (reanalysis from
retained bytes) and the RX-02 gap audit compare MacScope's own projections against them.
**No specimen is ever executed.**

## The engines are the worker's engines

The oracles are the natively linked engines of `AnalysisWorkerXPCService`, not side tools:

- LIEF 1.0.0 (`ThirdParty/LIEF`; Mach-O, PE and COFF modules only);
- pe-parse 2.1.1 (`ThirdParty/PEParse`);
- go-macho 1.1.283, the Mach-O parser inside ipsw (`ThirdParty/GoMachO`, a cgo c-archive);
- MacScope's C bridge over all three (`MacScope/ParserEngines`).

`Scripts/dependencies/build_parser_engines.py` builds each of these once per cache key into the
shared content-addressed dependency cache and stages them. The cache key binds the source tree,
the builder, and the clang/SDK/CMake/Ninja or Go identity. Xcode links the staged archives, and
the worker cross-checks every thin Mach-O slice and PE image against MacScope's loader
(`ParserCrossCheck`, warning diagnostics). The bridge's developer CLI `macscope-parser-dump`
drives the same code for the goldens.

Apple `dyld_info` covers the host dyld cache. The public LIEF build has no dyld-cache support,
and ipsw's dyld package is not linked (see the RX-03 report).

## One command

```bash
/usr/bin/python3 Scripts/parser-oracles/run_parser_oracles.py --write   # regenerate goldens
/usr/bin/python3 Scripts/parser-oracles/run_parser_oracles.py --check [--skip-host] [--receipt <file>]
```

The runner stages the engines first. Staging is a no-op when nothing has changed, and builds
once when a pin or the toolchain changes. A cold build is a heavy job, so run it under the
heavy-gate lock; a dev loop that builds the worker does this for you.

`--check` exits 1 when any golden differs from a fresh run. If the host dyld cache has changed
(a macOS update), its golden is reported as `stale` rather than failed; rerun `--write` and
review the diff.

## Files

| Path | Role |
|---|---|
| `oracles.lock.json` | Engine pins and vendored source paths, plus the corkami per-file Git blob identities and terms. Tests check that it agrees with `THIRD_PARTY_COMPONENTS.yml` and the builder. |
| `fixtures.json` | The 13 curated fixtures: format, classification (`valid`/`boundary`/`malformed`), slice selections, oracles and consumers. |
| `specimens.py`, `specimens/` | The deterministic generator and the committed bytes of 8 synthesized Mach-O/PE specimens. |
| `run_parser_oracles.py` | The runner. It stages the engines, runs them on private, non-executable copies of each specimen, normalizes the output, records agreement, and writes `goldens/<id>.json`. |
| `normalize.py` | Maps the engines' shared raw schema and the dyld_info text onto MacScope's closed fact schema. |
| `oracle_toolkit.py` | Offline helpers: pins, SHA-256, Git blob identity, engine identities. |

## Golden contract (`macscope.parser-oracle-golden.v2`)

- `input`: specimen path, size and SHA-256. For the host dyld fixture: every cache file's name,
  size and SHA-256, plus the macOS version and build.
- `tools`: for each engine, its version, Git revision, the SHA-256 of its vendored source tree,
  and the SHA-256 of the bridge source tree. For `dyld_info`: its executable SHA-256 and the
  macOS build.
- `results`: for each oracle and selection, the exact command with placeholders; `parsed` with
  normalized facts, or `rejected` with a bounded diagnostic.
- `agreement`: for each selection, the oracle statuses, the facts that every parsing oracle
  agrees on, the facts they disagree on (with every value), and the facts only one oracle
  reports.

Disagreement is evidence, not an error. The goldens freeze it, so a parser change or an engine
upgrade shows up as a reviewable diff.
