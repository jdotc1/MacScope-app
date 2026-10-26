# Bounded Swift demangler conformance samples

`Symbols.json` contains **433 unique stable Swift symbols** and their canonical display strings from Xcode 27.2 / Apple Swift 6.4 `swift-demangle --expand`. All inputs come from the three adjacent sample source files; no system binary was scanned. The inventory includes global symbols, undefined references, and compiler-local `l_$s` runtime records. It also retains all 257 other object symbol-table records by category, so extraction omissions are reviewable.

The source exercises generics; associated and primary associated types; constrained existentials; closures/captures; async, throws, and typed throws; property wrappers; result builders; `@Observable` macro expansions; parameter packs; opaque returns; actors and distributed actors; Objective-C bridging; and `#_hasSymbol`. `WeakUse.swift` imports an actually weak declaration from `WeakLibrary.swift`, producing a real `TwS` query. The local `#_hasSymbol` expression in `Samples.swift` intentionally remains in the original capture; its compiler warning is not evidence of weak linking.

The baseline parser returned nil for 163/433 symbols and matched the other 270 exactly. The implementation after this tranche matched 433/433, with zero nils and zero incorrect rendered strings, in the retained standalone sample comparison. The app-target XCTest case reads this same oracle fixture through `TestSourceRoot`; it does not invoke `swiftc`, regenerate expectations, or scan additional binaries. Native verification executed 76 focused Swift cases: the first run passed 73 and identified three existing wrapper regressions; after correcting them, a narrow retry passed those three plus this fixture. The other 72 passing cases reuse the first receipt. No unrelated suites or unchanged oracle captures were repeated.

## Capture and regenerate

Only capture again for changed sample/toolchain inputs or with the owner's explicit authorization. `capture` refuses an existing output directory; it compiles only these three source files, captures every object symbol-table entry, and calls the oracle once for the unique stable-symbol set. It performs no downloads.

```sh
python3 Scripts/demangler-conformance/generate.py capture \
  --output-dir t8-next-changed-capture
python3 Scripts/demangler-conformance/generate.py fixture \
  --capture-dir t8-next-changed-capture \
  --output Scripts/demangler-conformance/Symbols.json
```

The fixture phase only consumes retained `*-nm.txt`, `oracle*expand.txt`, and `capture.json`; it never recompiles or reruns the oracle. The initial capture was assembled from the original commands at `t8-demangler-evidence` and imported through this phase without repeating compilation. The complete expanded trees, original objects, baseline, changed-parser comparisons and native run log remain there. Expected strings are the oracle's final display lines, not the expansion tree's indentation or strings manufactured from our parser output. Exact comparison is valid because both render the same canonical representation; no whitespace normalization is used.

## Coverage boundary

The 257 other records include Objective-C runtime records, symbolic metadata labels containing unresolved relative-reference placeholders, references to stable symbols embedded in other record names, and ordinary runtime/local labels. These are preserved in `otherObjectRecords`; they are not standalone `$s` / `$S` manglings and are not silently passed off as decoded symbols. This work does not resolve binary-relative symbolic metadata references, qualify legacy `_T` mangling, cover every Swift grammar production, or validate installed GUI behavior. It is a bounded compiler-sample conformance fixture, not a system or binary corpus.

## T15 bounded follow-up

`Followup.swift` and `Followup.json` are separate from the retained 433-symbol T8 fixture. Seven selected compiler names cover three `_TtC` Objective-C runtime class names (including a nested class), ordinary repeated substitutions, and extended `A6_` / `A0_` substitutions. These expectations are exact final lines from Swift 6.4 `swift-demangle --expand`. The old `_TF` function grammar is still unsupported and unverified: this compiler emits stable function manglings. No older toolchain was downloaded.

The same tiny linked sample supplies eight exact metadata-section byte ranges, preserving their original virtual addresses and file offsets. `DemanglerTests` constructs a bounded file view from these bytes and exercises the existing `SwiftMetadataParser` direct-relative reference path for `Leaf`, `[Leaf]`, `Leaf?`, and `Box<Leaf>`. A separate mutation of the displacement bytes must leave those references unknown. No host-memory dereference, system binary, or rendered-text interpretation is involved. Indirect/GOT symbolic references and other symbolic control kinds remain unverified by this fixture; the string-only demangler does not resolve binary addresses.

For changed sample input, `python3 Scripts/demangler-conformance/followup.py capture --output-dir <new-external-directory>` compiles and captures only this bounded sample. `fixture --capture-dir <directory> --oracle <retained-oracle.txt> --output Scripts/demangler-conformance/Followup.json` consumes that capture without compilation or oracle calls. Multiple `--oracle` arguments allow reuse of unchanged names' earlier oracle captures when adding a new sample function. Do not regenerate or rerun unchanged captures. The original T15 capture compiled the initial sample once, then added `extended` and captured only its new oracle; both retained oracle files contribute to this fixture.
