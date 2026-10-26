# Golden differential fixtures (MacScope vs. oracle)

This directory backs `GoldenDifferentialTests`: it lets you diff **MacScope's** normalized
analysis output against an **authorized reference** for the same binary, so "parity" can mean
*"matches a real disassembler"* instead of *"compiles + unit-green."*

Two oracles are supported, each emitting the **same** `GoldenOutput` schema so the one
`GoldenOutputDiff` engine compares both unchanged:

| Oracle | Reference file | Capture tool | License posture |
|--------|----------------|--------------|-----------------|
| **Reference** | `ls/reference.json` | `Scripts/reference_golden_export.py` (a GUI disassembler's Python console) | proprietary — clean-room |

## How it works

1. `GoldenDifferentialTests` analyzes a real in-scope binary (`/bin/ls`) through MacScope's
   pipeline and normalizes it to a `GoldenOutput` (the schema below).
2. If `GoldenFixtures/<binary>/reference.json` exists, it decodes it and evaluates the **trusted gate**
   (`GoldenGate.evaluate`) — see the next section — failing only on a **real, un-accepted**
   divergence (a decode error, missing import, or genuine named-function/code-symbol coverage
   regression).
3. If it does not exist, the differential **skips** with a message pointing here. (The MacScope
   side is still self-validated: `testRealBinaryRoundTripsAndSelfMatches`.)

## The trusted gate (what turns the build red)

The raw `GoldenOutputDiff` reports **every** structural difference, which is the right thing for
eyeballing but the wrong thing for a build gate: oracle exporters can have different scopes (the
reference exporter still leaves imports/exports/CFG/xrefs/demangled names empty), and each tool uses
different conventions for the rest (Mach-O `SEG,SECT` vs bare section names, symbol-`kind`
vocabularies, import stubs modeled as `imports` here vs `procedures` there, auto-generated
`loc_`/`FUN_`/`byte_` labels). Demanding an exact match against that conflates three unlike things
— *real divergence*, *oracle scope*, and *convention* — so the differential would be permanently red
and worthless as a gate.

`GoldenGate` (`MacScope/Tests/CoreTests/Support/Golden/GoldenGate.swift`) separates them. It fails the build **only** on:

- **DECODE** — a shared-address instruction whose mnemonic/operands are not semantically equivalent
  after `OperandNormalizer` (which now also folds width-masked addressing offsets, e.g.
  `[sp, #-0x10]!` ≡ `[sp, #0xfff0]!`), **unless** the address is in the committed allowlist
  (`GoldenGate.acceptedDeltas`).
- **IMPORTS** — every import the oracle reports must exist in MacScope's import set after
  `normalizedSymbolName` (leading underscores stripped, lowercase). Library path and ordinal
  metadata differences stay visible in the raw report but do not fail the gate. A known environment
  import delta can be accepted through `GoldenGate.acceptedDeltas`.
- **COVERAGE** — a **named** function or **named** code symbol the oracle has that MacScope lacks,
  after excluding import stubs (`__stubs`/`__auth_stubs`/GOT), oracle auto-labels, names MacScope
  models under `imports`, and any address outside the loaded image or in a non-executable section.

Everything else — binary metadata, section naming, symbol-`kind` taxonomy, exports, CFG/xref
differences, demangled-name gaps, basic-block boundaries, pseudocode, stub procedures, and unnamed
auto-discovered functions — is **reported** (printed in the test output) but never fails the build.
Imports have graduated from reported-only to gated; CFG and xrefs remain reported-only until their
cross-tool vocabulary is tight enough for a trusted gate.

The allowlist is **committed and clean-room safe**: each entry names only a `/bin/ls` address or
import symbol key and a human reason, never any oracle output. Today it holds exactly one entry (a
`BFI`/`BFM` alias where MacScope emits the preferred alias and the reference output uses the raw encoding). A passing
run still prints the full report, so the standing oracle-scope differences stay visible; a failing
run prints exactly what regressed. The classification is unit-tested fixture-free in
`GoldenGateTests` (runs in CI without any oracle JSON).

## Clean-room rule (important)

**Never commit an oracle reference.** `reference.json`, `ghidra.json`, and any `macscope.json` are
git-ignored. Capture them locally, diff them in place, and record only the *diff result* — never a
third-party tool's output or any of its code/resources. This directory commits only this README and
the `.gitignore`.

## Layout

```
GoldenFixtures/
  corpus/                     <- COMMITTED reproducible sources for the corpus binaries
    swift_corpus.swift
    objc_corpus.m
  ls/                         <- /bin/ls (a real arm64e system executable)
    reference.json  <- you produce this (git-ignored); an authorized reference export, normalized
    ghidra.json     <- you produce this (git-ignored); stored reference output, normalized
    macscope.json   <- optional; MacScope's own output for eyeballing (git-ignored)
  swift_corpus/               <- built + captured locally (all git-ignored)
    swift_corpus    <- the arm64e dylib, built by Scripts/build_golden_corpus.sh
    ghidra.json / reference.json / macscope.json
  objc_corpus/
    objc_corpus / ghidra.json / reference.json / macscope.json
```

## Corpus: modern-binary shapes beyond `/bin/ls`

`/bin/ls` is a C executable, so it exercises no Swift metadata, no mangled Swift symbols, and no
Objective-C classes / `objc_msgSend` dispatch. The **corpus** extends the differential to those
modern shapes with two small arm64e dylibs built from the committed sources in `corpus/`:

- **`swift_corpus`** — structs/classes/enums/protocols, generics, closures, Array/Dictionary/String
  (Swift `__swift5_*` metadata + mangled symbols).
- **`objc_corpus`** — an ObjC class with a category, properties, methods, blocks, and Foundation
  calls (ObjC class lists + the modern `__objc_stubs` `_objc_msgSend$<selector>` dispatch stubs).

Enable them (binaries + references are all git-ignored, built/captured locally):

```bash
Scripts/build_golden_corpus.sh                                              # build both arm64e dylibs
```

`GoldenDifferentialTests` then picks them up (`testSwiftCorpusGhidraDifferential`,
`testObjCCorpusGhidraDifferential`, plus `…Reference…` variants that skip until you capture a
reference export). The corpus already paid for itself: it surfaced the `__objc_stubs`
selector-dispatch section (which `/bin/ls` lacks), correctly classified by the gate as a stub section
rather than missing functions.

## The schema (`GoldenOutput`)

Defined in `MacScope/Tests/CoreTests/Support/Golden/GoldenOutput.swift` (`schemaVersion` is currently **1**). Your
`reference.json` must be a JSON object of this shape. **Normalization rules** (match these or the
diff will report false differences):

- **Addresses** are lowercase hex **strings** with a `0x` prefix: `"0x100003a40"`.
- **Binary path** is the **basename** only (`"ls"`), never an absolute path.
- **Embedded UUID** is dropped: emit `hasEmbeddedUUID: true/false`, not the UUID string.
- Collections may be in any order (the diff keys them); empty collections are allowed.

```jsonc
{
  "schemaVersion": 1,
  "binary": { "name": "ls", "pathBasename": "ls", "kind": "executable",
              "architecture": "arm64", "hasEmbeddedUUID": true,
              "platformName": "macOS", "minimumOSVersion": "12.0",
              "sdkVersion": "14.0", "buildTools": [] },
  "sections":     [ { "name": "__text", "address": "0x100003a40", "size": 256,
                      "fileOffset": 0, "isExecutable": true, "isZeroFill": false } ],
  "symbols":      [ { "name": "_main", "address": "0x100003a40", "kind": "function",
                      "libraryName": null } ],
  "imports":      [ { "name": "_printf", "libraryName": "libSystem", "libraryOrdinal": 1 } ],
  "exports":      [ { "name": "_main", "address": "0x100003a40", "source": "symtab" } ],
  "instructions": [ { "address": "0x100003a40", "bytes": "fd 7b bf a9", "mnemonic": "stp",
                      "operands": "x29, x30, [sp, #-0x10]!", "comment": null } ],
  "procedures":   [ { "name": "_main", "startAddress": "0x100003a40",
                      "endAddress": "0x100003b00", "confidence": 1.0 } ],
  "basicBlocks":  [ { "procedureStartAddress": "0x100003a40", "startAddress": "0x100003a40",
                      "endAddress": "0x100003b00", "instructionCount": 4 } ],
  "controlFlowEdges": [ { "from": "0x100003a40", "to": "0x100003b00", "kind": "fallthrough" } ],
  "crossReferences":  [ { "from": "0x100003a44", "to": "0x100008000", "kind": "call" } ],
  "demangledNames":   [ { "mangled": "_Z3fooi", "demangled": "foo(int)" } ],
  "pseudocode":       [ { "procedureStartAddress": "0x100003a40", "procedureName": "_main",
                          "returnType": "int", "lines": ["int _main() {", "}"] } ]
}
```

## Capturing the Reference oracle (proven recipe)

`Scripts/reference_golden_export.py` is a clean-room exporter that runs inside a GUI disassembler's
Python console (where `Document`/`Segment`/`Procedure` are pre-injected globals) and writes
`~/reference_golden.json` in the schema above. Steps:

1. Open the disassembler, read the executable (`/bin/ls`), pick the **AArch64** slice (the arm64e one
   MacScope selects), run automatic analysis, and wait for it to finish.
2. In its Python console, run the exporter (UTF-8 read avoids an ASCII-locale `UnicodeDecodeError`;
   this script is ASCII-clean so plain `open` also works):
   ```python
   exec(open('.../MacScope/Scripts/reference_golden_export.py').read())
   ```
   It prints `REFERENCE_EXPORT_DONE -> ~/reference_golden.json counts={...}`.
3. Sanitize + place it (clamps any non-negative ints, drops helper keys, validates the shape):
   ```bash
   python3 -c 'import json,sys; d=json.load(open(sys.argv[1]));
   [s.update(size=max(0,int(s["size"])), fileOffset=max(0,int(s["fileOffset"]))) for s in d["sections"]];
   json.dump(d, open(sys.argv[2],"w"), indent=2)' \
     ~/reference_golden.json MacScope/Tests/CoreTests/GoldenFixtures/ls/reference.json
   ```
4. Run `GoldenDifferentialTests/testReferenceDifferential` — it prints the per-capability diff.

You do **not** have to populate every collection: an empty reference collection makes the diff
report MacScope's entries as `only-in-MacScope` (expected). The reference exporter's API path
currently lacks typed imports/exports/CFG/xref export in this clean-room script, so it leaves
imports, exports, controlFlowEdges, crossReferences, demangledNames, and full binary metadata empty.
Reference outputs may cover different fields; the trusted gate accounts for this.

## Running it

```
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  xcrun xcodebuild test -project MacScope.xcodeproj -scheme MacScopeApp \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:CoreTests/GoldenDifferentialTests
```

Runs both oracle differentials. With no `reference.json`/`ghidra.json` each skips; with one present
it evaluates the trusted gate, printing the full report (gated + accepted + reported) and failing
only on a real, un-accepted decode or coverage divergence.
