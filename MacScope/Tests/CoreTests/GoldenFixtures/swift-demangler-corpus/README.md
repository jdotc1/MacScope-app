# Swift demangler reference corpus

`corpus.json.gz` backs `SwiftDemanglerCorpusTests`. It holds 25,580 distinct Swift manglings. For each one it records the Swift 6.2 reference rendering, or `null` where the reference rejects the name. Each name is run through `Demangler.mangledToReadable`, the same entry point the corpus used.

## Provenance

- **Source:** reference data recorded on 2026-10-13.
  - Source schema: `macscope-swift-demangler-corpus-1`.
  - 24,637 names are harvested from synthetic Swift modules compiled for this corpus.
  - 943 names are literals from MacScope's pinned demangler tests and `Symbols.json`.
- **Reference:** Swift 6.2 RELEASE `swift-demangle --compact`, from the official Ubuntu 22.04 x86_64 distribution (target `x86_64-unknown-linux-gnu`). Exact text, with no normalization.
- **Harvesting:** LLVM nm 19.1.7 (Debian 1:19.1.7-3+b1).
- **Product baseline:** jdotc1/MacScope-app `5a1c0acdb2f8a98cd2e17c99be67876892cdb01d`. The four demangler files are unchanged on main as of this harness.

## Slice

Each entry keeps these fields from the delivery's `vectors.json`:
- `mangled`
- `expected` (the reference's compact output, or `null`)
- `status` (the corpus's classification at the baseline)
- `node_kind`, the first non-Global reference node. It's a grouping, not the failing production.
- `baseline_result`, MacScope's text, kept only for the 44 names where it disagreed with a non-null rendering.

Expanded trees, simplified forms and origins are not included in this fixture slice.

## Integrity

| File | Bytes | SHA-256 |
|---|---:|---|
| `vectors.json` (as delivered; matches the `SHA256SUMS.json`) | 47,460,057 | `336a7d74719d329e16320063e767b18332f285b42a53cb12304953f72c90baf8` |
| `corpus.json.gz` (this slice, `gzip -9 -n`) | 274,028 | `ba15aadde59a86834332991c422b78127a3f544586cb7a167e5ac929730369c4` |

The hashes are recorded once, here. The test does not re-hash the file on each run.

## Gates

`baseline-match.txt` lists the names that match: 21,497 of 25,580 at the first Mac run on 2026-10-13 (the same set as the corpus's Linux run), 21,502 after the `fD` and `MD` fixes. `SwiftDemanglerCorpusTests` fails in two cases:
- Any of those names stops matching.
- Any name renders text the reference disagrees with, beyond the 44 disagreements the corpus recorded, each with its own text. In other words, a nil may never turn into a wrong name.

`REPORT-20261013.md` is that first run's report, with counts by outcome and reference node kind and every non-nil disagreement:
- **25 wrong outputs:** 24 are the Swift 6.2 `modify2`/`read2` versus newer `yielding_mutate`/`yielding_borrow` display rename, and one is the `fD` deinit defect.
- **19 accepted only by MacScope:** Apple-dialect `MR`/`Md` metadata forms and one `vpfF`.
- **4,039 unsupported:** nil, which falls back to the raw name.

## Regenerating

Don't edit the slice by hand. A new corpus delivery replaces `corpus.json.gz`, and this README gets the new hashes and versions. After that, re-record `baseline-match.txt` from one run with `TEST_RUNNER_MACSCOPE_DEMANGLER_CORPUS_RECORD_BASELINE=1`.
