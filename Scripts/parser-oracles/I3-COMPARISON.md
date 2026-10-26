# I3 comparison and local integration

Reviewed DESIGN.md, SWIFT-DISAGREEMENTS.md, GH-REFUSAL.md and patches 0001–0005 from the I3 extracted return. Draft commits were not merged; the applicable code was adapted to the existing K1/K2 interfaces and tested locally.

## Adopted

- K1: thin-file command/section/relocation preflight, restricted go-macho load-command parsing, list alignment and aggregate count admission, cooperative read/time budgets, UTF-8/name bounds, sentinel normalization, omitted unknown addresses, fallible C allocation and export-level panic recovery.
- Both exports: JSON size precharge with exact escaping for the linked encoding/json; added map support required by K1's existing schema. CLI inventory reads now allocate only the admitted fixed length and reject changed-length input.
- K1 comparison: conformance descriptor and type descriptor identities, six-domain presence and nonvacuous generic unknown-layout assertions. The local failure showed that native MacScope resolves Color's Equatable/Hashable conformances; the oracle preserves raw _$sSQMp/_$sSHMp. The ledger now records a naming difference, not absent native metadata.
- K2: validated legacy/modern headers, function interval and descriptor agreement, advertised file/CU references, bounded PC-value stream validation, source mapping agreement with gosym, typed refusal and no partial seed admission.
- K2: audited zero-header profile with embedded Go version and explicit JSON provenance. Included I3's go1.27.1 and independently inspected the installed go1.27.2 linker source, which also writes that historical word as unused. Exact versions only; nonzero mismatches, missing/older/devel/unaudited versions refuse.
- Tests: six metadata Go test groups and nine pclntab Go test groups, with 33 subcases; native fixture/gh tests remain the real-binary owners. The malformed native fixture test now copies read-only mapped data before mutation.

## Deliberately not adopted

- Alternate C symbol names, free function and JSON schema: retained the already-integrated ABI and existing malloc/free ownership. The same safety mechanisms are applied behind those interfaces.
- Blanket rejection of every K1 per-domain failure: retained explicit partial status plus named domain errors for developer diagnostics; success never hides an error. K2 remains all-or-nothing.
- I3's Ice/Sentry/terminal-notifier assets and goldens: retained the three small authored specimens already compiled and captured locally. Importing cloud goldens without their exact binaries/native comparison would not establish local acceptance and would enlarge this scoped run.
- Cloud counts and acquisition/hash receipts: retained as source context only, never substituted for the local /opt/homebrew/bin/gh XCTest result. No downloads, binary-wide sweeps or repeated hashes.
- Test-time compilation and per-Go-version downloaded real fixtures: retained the existing Go1.27.2 stripped fixture and synthetic format/refusal vectors. No fixture was rebuilt or executed.
- 128 MiB input allowance: kept the stricter existing 64 MiB image ceiling. K1 output remains 8 MiB; K2 now has a precharged 16 MiB JSON ceiling and a separate 12 MiB worker string ceiling.
- Schema-only duplicate golden scripts and oversized-allocation input tests: existing focused golden checks and new bounded admission vectors cover the changed behavior without duplicate checks or large allocations.
- Cloud claims of source-only disagreements do not establish additional local defects. Non-lazy-only metadata coverage, broader binaries, full gh decompilation and watchdog timeout execution remain outside this bounded acceptance.

## Local evidence

The first native attempt completed compilation and ran four tests: 0 passed, 4 failed. Failures were retained and addressed: raw/resolved conformance expectation, zero-header profile rejection, fixture name recovery, and mapped-buffer mutation crash. The build log's repeated exit-code-zero Swift driver diagnostics did not prevent test execution and are not treated as a failed toolchain.

Focused Go run: 15 top-level tests passed, 33 subcases passed, 0 failures; package runtime 0.134 s. No unchanged prior Python tests were repeated. Native results: TypeAtlasOracleTests passed 1 case and GoPclntabTests passed malformed refusal in the first corrected run. The final focused run passed the other 3 GoPclntabTests cases (fixture naming/symbol precedence/actual discovery, real gh witness, and new linker-data admission). Five distinct native cases passed; passing cases were not repeated. Final warm run: lock 309.2 s, preparation 0.3 s, build 34.7 s, tests 7.3 s.

The second native run exposed an I3 integration omission: Go's linker includes go:buildid and go:textfipsstart/end data in pclntab. Worker admission now validates but excludes those exact data-marker rows from instruction seeds and names; the Go output remains faithful metadata. The focused test also proves arbitrary unaligned code rows still refuse.

Actual /opt/homebrew/bin/gh XCTest result: 42,388 parsed pclntab rows, 42,385 recovered function seeds/names after excluding three linker-data markers; symbols 147 → 42,532 and seeds 0 → 42,385. Exact embedded version go1.27.1, text-base provenance from __text with zero historical header.

| Address | Before | After |
| --- | --- | --- |
| 0x100e4ed10 | no symbol | main.main |
| 0x10004bd70 | no symbol | runtime.main |
| 0x100088dd0 | no symbol | runtime.goexit |

These are compiler-metadata and worker-admission counts, not a full gh analysis/decompilation pass. The stripped authored fixture additionally passed actual AnalysisEngine function-name discovery. No binary-wide sweep, installation or /Applications/MacScope.app access occurred.
