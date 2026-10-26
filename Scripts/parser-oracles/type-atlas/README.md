# Type Atlas oracle specimens (K1)

Exactly three authored, compile-once arm64 Mach-O specimens: a Swift executable,
a mixed ObjC/Swift dylib, and an ObjC executable. Adjacent sources are authoritative.
The binaries are parser data and must never be executed by the oracle runner.

Compile commands (Xcode 27, macOS 27.0 target):

```
xcrun swiftc -target arm64-apple-macos27.0 -module-name TypeAtlasSwift swift-app.swift -o swift-app.bin
xcrun swiftc -target arm64-apple-macos27.0 -emit-library -module-name TypeAtlasMixed mixed.swift -o mixed.dylib
xcrun clang -arch arm64 -mmacosx-version-min=27.0 -fobjc-arc -framework Foundation objc.m -o objc.bin
```

After the one combined K1/K2 archive build, generate only these goldens:

```
Scripts/parser-oracles/run_parser_oracles.py --write --type-inventory --no-stage --engines-root <completed-stage>
```

The runner consumes STAGED.json, never re-hashes the unchanged vendor tree, invokes
only the developer CLI, and enforces its existing subprocess deadline/output bound.
The C export caps input at 64 MiB, inventories at 16,384 rows each, strings at
16 KiB per row, and JSON at 8 MiB. Upstream calls are synchronous; the subprocess
is the deadline boundary. A per-reader failure is recorded as partial, never an
empty successful inventory. This oracle is not called during ordinary analysis.

## Disagreement ledger

The three goldens were generated once with the combined K1/K2 Go archive
`6a025ace8b541dce35883feb5bde21d08824da42905c6399e591d65491264f47`.
All six reader inventories returned `parsed`; no per-reader error occurred.
The first native comparison found one failing expectation: the test excluded the
external `Color` conformances, but MacScope had correctly resolved both protocol
names. The corrected comparison is pending the root-owned focused run.

| Specimen | Oracle fact | Catalog representation / cause |
|---|---|---|
| Swift app | Protocol `Shape`, descriptor 4294974072 | No standalone Swift protocol row kind exists. Its name is retained on `Point`'s conformance. |
| Mixed dylib | Protocol `Runner`, descriptor 4956 | Same standalone Swift protocol limitation; retained on `Pair`'s conformance. |
| Swift app | `Point` conforms to `TypeAtlasSwift.Shape` | In-image catalog descriptor names are unqualified (`Shape`); the test removes only this authored module prefix. |
| Mixed dylib | `Pair` conforms to `TypeAtlasMixed.Runner` | Same explicit module-qualification difference (`Runner`). |
| Swift app | `Color` conforms to external `_$sSQMp`, conformance descriptor 4294973760 | MacScope resolves this descriptor symbol to `Equatable`. This is a raw-symbol versus resolved-name representation difference, not a missing conformance. |
| Swift app | `Color` conforms to external `_$sSHMp`, conformance descriptor 4294973800 | MacScope resolves this descriptor symbol to `Hashable`; the conformance is represented. |

The test enumerates the two external rows exactly and maps only `_$sSQMp` to
`Equatable` and `_$sSHMp` to `Hashable`. It compares all conformance names and both
conformance/type descriptor addresses; no external row is excluded. Raw goldens
remain unchanged. Generic fields remain represented with unknown offsets. ObjC protocol
comparison uses descriptor-backed rows; name-only external adoptions, if any,
are references with unknown evidence, not invented declarations. The plain ObjC
specimen contains actual `NSObject` and `Pinger` protocol descriptors.

Validation performed: compile-once sources succeeded; the single Go archive build
took 5.1 s, C++ bridge 1.9 s, total stage 8.293 s. LIEF and pe-parse were cache hits.
Four CMake workers, three concurrent specimen compiler processes, exclusive heavy
lock. No corpus, unchanged validation replay, installed app or UI action.

## I3 review reconciliation

The I3 `SWIFT-DISAGREEMENTS.md` describes possible representation differences from
source inspection, not observed failures of these three specimens. Its guidance
to compare descriptor identities, preserve raw names, distinguish external
adoptions from declarations, and retain unknown generic layouts is incorporated
in `TypeAtlasOracleTests`. All six inventory domains must be present; descriptor
rows must retain address identities, and the generic assertion cannot pass with a
missing type or empty member list. The separate I3 Ice/Sentry/terminal-notifier
goldens are not substituted for these three authored specimens.

I3 patches 0001/0004/0005 also propose Go boundary hardening (raw load-command and
section preflight, read budgets, output-size precharge, nullable vendor sentinels,
and fallible C allocation). Those shared bridge changes are reviewed and
integrated by the root Go owner separately; this test/ledger change makes no
claim that they have been adopted or validated.
