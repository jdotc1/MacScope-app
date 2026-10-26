# E4 export instruction index — 2026-10-16

Base: fresh `github/main` `da2fc04f2`. Tested source: `8035b0a6d`.

The DocumentExportService whole-image path reaches exactly two image-wide row scans:
`pseudocodeTarget` and `codeExcludedAddresses`. No image-wide xref scan is reached.
Phase2ReadProjector, EditorSurfaceView, callers/callees, the exact-function-ID
Reconstruction scan, and Tools/NativeDecompilerBridge are unchanged.

An immutable per-image address index selects rows by two binary searches. Original
array offsets retain duplicates and shuffled input order; fixed-width radix ordering
keeps restoration O(k), so each slice is O(log n + k). The index and loader exclusion
set are built once per row/data-range generation. A separately memoized per-slot
exclusion set includes authored overrides, avoiding a repeated image-sized set union.
NSLock protects publication; row/range writes replace the image memo and workspace
analysis/authoring writes replace the exclusion memo. Snapshot copies retain their
original generation. Other per-function symbol/function scans remain outside scope.

## Single focused run

`MACSCOPE_DEV_SLOTS=1 MACSCOPE_XCODE_JOBS=4 Scripts/dev_loop.sh CoreTests/DocumentExportServiceTests`

17 tests passed, zero failures/skips. New cases:
- `testLibjpegIndexedSlicesMatchReferenceAndReportSinglePassTiming`: every function's
  complete rows and selected function equal the old test-only linear implementations.
- `testIndexedSlicesPreserveOrderExclusionsAndSnapshotCopies`: shuffled rows, duplicate
  addresses, disjoint executable segments, loader exclusions, degenerate/overflow
  bounds, authored exclusions, and snapshot-copy mutation isolation.
- `testWholeImageTextEqualsReferenceScans`: the existing two-function fixture, both
  with and without loader data ranges, is byte-identical using reference scan results
  through the same printer. All existing DocumentExportServiceTests ran once.

Named witness `/opt/homebrew/lib/libjpeg.8.dylib`: 914 functions, 89,732 rows,
0 codeDataRanges. One pass each, same process, no warmup/repeats:
- Reference: **20.834314417 seconds**.
- Indexed: **0.302328291 seconds**.

These are slice/target timings, not end-to-end rendering timings. Analysis and
assertions are outside the timing intervals; the indexed pass includes index setup.
The fixture covers codeDataRanges, which this real witness does not contain.

Brief discrepancy: I6MergedUpsampleWitnessTests on this base has no loader or
WorkspaceSnapshot helper: it decodes embedded symbol hex with ARM64Decoder.
The new test uses the existing AnalysisEngine.analyze(url:) whole-image loader,
whose ARM64 path uses that same decoder. Only a missing binary permits XCTSkip;
the method is registered in the skip allowlist.

Lock wait 194.9s; preparation 27.4s; build-for-testing 196.3s; tests 29.0s;
total 447.5s. Xcode 27.2, Swift 6.4.2, macOS 27.2 SDK; four Xcode jobs, one
exclusive dev slot. Queued once behind E5. An initial allowlist-order error in this
change was corrected before compilation/tests began. The completed invocation
emitted cache-related “exit code 0 but produced no further output” diagnostics but
continued successfully in that same invocation; no build retry or cache workaround.

Retained evidence (local navigation):
- local evidence (not included) (preflight failure).
- local evidence (not included) (successful run).
- local evidence (not included).
- local evidence (not included) (existing-result
  diagnostic export containing the printed timing line; no test rerun).

Read-only in-thread lane `/root/export_path_review` audited the export path once,
with inherited model/effort and no edits or native runs. Root owned implementation,
references, integration and the single focused test execution. No GUI, installation,
running-app interaction, native export command, corpus pass, or rendered-text cache.
PR is for decompiler-lead review; no merge is authorized in this lane.

## Run 3: merge PR #765

Merged fresh github/main `219af980a` into this branch with merge commit
`20d970c4f26188a82215b4041d7d4b015d64859f` (no rebase). Resolved conflicts in
AnalysisModels+WorkspaceSnapshot.swift and AnalysisModels.swift, retaining both
memo implementations. DocumentExportService.swift auto-merged cleanly.
All four snapshot invalidation setters reset the indirect-call identity/memo and
export exclusion memo. ImageAnalysis instruction/range mutations still replace
the slicing index. The imageWideIndirectCalls build loop uses indexed pseudocodeTarget.

Strengthened the copy/mutation fixture with direct index reads, memo-identity
assertions and reference comparisons after each instruction/range mutation.
The first new inequality assertion used 0x1006, inside the existing loader-data
range, so the visible result correctly remained unchanged. Fixture correction
`51aa70fd7` places the new row at unexcluded 0x100A; no product correction needed.

One requested class run on the merge: DocumentExportServiceTests 16 passed / 1
failed; IndirectTargetResolutionTests 11 passed. Zero skips. Only the changed
fixture was then run, passing 1/1. Combined coverage: 17 export and 11 indirect
resolution tests accepted; the 27 already-passing cases were not repeated.
Commands used Scripts/dev_loop.sh with MACSCOPE_DEV_SLOTS=1 and
MACSCOPE_XCODE_JOBS=4, retaining the original project/DerivedData and heavy lock.
First run: lock 9.0s, preparation 0.4s, build 190.8s, tests 39.2s, total 239.4s.
Changed-fixture run: lock 8.6s, preparation 0.3s, build 31.3s, tests 4.6s, total 44.8s.
Logs (local navigation): local evidence (not included) and
local evidence (not included)
No fresh run root, cache wipe, tooling retry, installation or GUI acceptance.
PR #766 remains open for the decompiler lead to review and merge.
