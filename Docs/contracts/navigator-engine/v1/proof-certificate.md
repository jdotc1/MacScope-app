# Proof certificates and provenance resolution (v1)

This page defines three things:

* the proof-certificate record that every `proven` fact must cite;
* the grammar that every provenance ref follows, and how each ref resolves to the bytes or record it names;
* the first in-app proof producer, `proof.function-start-structural@1`, and its non-proof companion, `derive.function-start-call-target@1`.

The Swift sources are in `MacScope/Services/NavigatorContract/`:

* `NavigatorProofCertificate.swift`
* `NavigatorProvenanceResolver.swift`
* `NavigatorContractValidation.swift` (the `proven` rule)

The producer and its companion are in `MacScope/Services/Analysis/Proofs/FunctionStartStructuralProof.swift`.

Nothing here changes `vocabulary.json`, the JSON Schema or `schemaVersion`. The certificate is a separate record kept beside the state. It is not a fifth record kind of `validateRecord`.

## 1. Where certificates sit

A `proven` fact cites its certificate with one provenance entry:

```json
{"kind": "proofCertificate", "ref": "sha256:<64 lowercase hex>"}
```

The ref is the certificate's `hash`. The fact's other provenance entries are:

* the rule entry, first, so that the fact id carries `rule@ruleVersion`, as README §2 describes;
* the premises the certificate lists.

The certificate entry carries no `rule`, so it never changes the fact id. Two runs of the same rule on the same claim produce the same fact id. They also produce the same certificate hash whenever they reach the same verdict from the same premises, because the hash leaves out `budget` (§2.2).

Certificates are kept by the store that persists the facts that cite them. The resolver looks them up by hash, through `NavigatorProvenanceResolver.Context(certificates:)`.

## 2. The certificate record

| Field | Type | Meaning |
|---|---|---|
| `rule` | non-empty string | Id of the rule that produced the certificate, e.g. `proof.function-start-structural` |
| `ruleVersion` | non-empty string | Version of that rule, e.g. `1` |
| `subject` | subject object | The fact's subject, with the same `kind`, `ref` and optional `image` as the fact |
| `predicate` | vocabulary predicate | The fact's predicate |
| `value` | contract value | The concluded value; it must type-check against the predicate as a settled claim (no `alternatives`) |
| `premises` | array of provenance objects | Every record the conclusion rests on, each resolvable under §3 |
| `assumptions` | array of strings | What the rule takes as given, not shown by a premise |
| `conclusion` | non-empty string | One sentence stating what was established, or why nothing was |
| `trustedBase` | array of strings | Components whose correctness the verdict depends on |
| `outcome` | `proven`, `refuted`, `insufficientEvidence`, `cancelled` or `timeout` | The verdict |
| `budget` | `{"wallMs": int >= 0, "bytesRead": int >= 0}` | Wall time of the run, and the total size of the premises' byte ranges. Validated, recorded and returned, but not hashed |
| `hash` | `sha256:<64 lowercase hex>` | SHA-256 of every field except `hash` and `budget`; see below |

The certificate has no other fields. A missing field, an extra field, or an extra `budget` key is refused.

### 2.1 Outcomes

| Outcome | Meaning | Can a fact be `proven` on it? |
|---|---|---|
| `proven` | Every premise holds and resolves | Yes |
| `refuted` | The premises establish the negation | No |
| `insufficientEvidence` | The run finished, but the premises do not establish the claim. Absence from a table is not disproof | No |
| `cancelled` | The caller cancelled the run before it finished | No |
| `timeout` | The run exceeded its wall-time limit | No |

A certificate is written for every outcome, so a run that stopped or failed still records what it read. Only a `proven` certificate supports a `proven` fact.

### 2.2 Hash

```
hash = "sha256:" + lowercase-hex( SHA-256( UTF-8( canonical( hashInput ) ) ) )
```

`hashInput` is the certificate without `hash` and without `budget`: the ten fields `rule`, `ruleVersion`, `subject`, `predicate`, `value`, `premises`, `assumptions`, `conclusion`, `trustedBase` and `outcome`. `canonical` is the contract's canonical encoding (README §2, `NavigatorJSONCanonical.encode`): object keys sorted by Unicode scalar, no whitespace, integers only. The digest is the codebase's `AnalysisFingerprintBuilder.sha256Hex`. `hash(of:)` refuses an input that contains `hash` or `budget`, with the reason `certificate: hash input must exclude <field>` for each one present.

Reading a certificate (`NavigatorProofCertificate(json:)`) recomputes the hash and refuses a mismatch, with the reason `certificate.hash: does not match recomputed sha256:…`. A certificate whose stored hash still recomputes is *intact* (`isIntact`).

The hash is reproducible. `budget` measures a run (its wall time and the bytes it read), so it is left out: two runs that reach the same outcome from the same premises produce the same hash, however long each took. Two certificates that differ only in `budget` have equal hashes. A certificate whose `budget` was edited after the fact still reads, with its hash unchanged and the edited budget; the budget is not attested by the hash. Everything that states the claim and the evidence for it is hashed: changing any other field changes the hash.

## 3. Provenance ref grammar and resolution

Addresses use the subject-ref spelling: `0x`, lowercase hex, no leading zeros. Indices are decimal with no leading zero (except `0`). For every canonical ref, `NavigatorProvenanceRef.parse(kind:ref:)` followed by `.ref` gives back the same text.

`NavigatorProvenanceResolver.resolve(_:in:context:)` never throws. It returns one of the following:

* `bytes(range, sha256)`: image bytes;
* `record(description, range?, sha256)`: a structured record;
* `rule(descriptor)`;
* `certificate`;
* `annotation(id)`;
* `unresolvable(reason)`.

Ranges are relative to the start of the selected slice, and `sha256` is the plain hex SHA-256 of the bytes the range covers. The reasons are:

* `unknownKind`: the kind is not in the vocabulary;
* `outOfBounds`: an index or address lies outside its table, section or slice;
* `noSuchRecord`: the ref is malformed, or names nothing, or names something that does not match;
* `hashMismatch`: a certificate's bytes do not hash to the cited hash.

Two failures apply to every kind:

* any kind outside `provenanceKinds` is `unknownKind`;
* a ref outside the grammar is `noSuchRecord`.

An image kind resolved without a parsable slice is also `noSuchRecord`.

| Kind | Ref | Resolves to | Unresolvable |
|---|---|---|---|
| `loaderRecord` | `lc[<n>]` | `record`: load command `n`, its full `cmdsize` bytes | `n` ≥ the number of commands, or the bytes run past the slice → `outOfBounds` |
| `loaderRecord` | `section[<segment>,<name>]` | `record`: the 80-byte `section_64` header | no header with that segment and name → `noSuchRecord` |
| `loaderRecord` | `functionStarts[<i>]@<address>` | `record`: the ULEB128 delta bytes of `LC_FUNCTION_STARTS` entry `i` | `i` ≥ entry count → `outOfBounds`; entry `i` is not `address` → `noSuchRecord` |
| `loaderRecord` | `exports[<i>]@<address>` | `record`: for an export from the trie, the terminal-info bytes of its trie node; for a symbol-table export, its 16-byte `nlist_64` | `i` ≥ `MachOFile.exports.count`, or the backing `nlist_64` is unreadable → `outOfBounds`; export `i` is not at `address`, its trie terminal is missing, or the terminal or symbol value disagrees → `noSuchRecord` |
| `loaderRecord` | `nlist[<i>]@<address>` | `record`: the 16-byte `nlist_64` entry `i` | no symbol table, `i` ≥ `nsyms`, or entry bytes outside the slice → `outOfBounds`; not an `N_SECT` symbol, or `n_value` ≠ `address` → `noSuchRecord` |
| `loaderRecord` | `unwind[<i>]@<address>` | `record`: the 4-byte function-offset word of `__unwind_info` second-level entry `i` | `i` ≥ row count, or the word runs past the slice → `outOfBounds`; entry `i` does not start at `address` → `noSuchRecord` |
| `loaderRecord` | any other `<table>[<i>]@<address>` | — | `noSuchRecord` |
| `decodedInstruction` | `<address>` | `bytes`: the 4 instruction bytes | no non-zero-fill section holds `address`, or its bytes are outside the file → `outOfBounds`; the section is not executable, or `address` is not 4-byte aligned → `noSuchRecord` |
| `metadataRecord` | `<section>@<address>` (`<section>` is `__name` or `__SEG,__name`) | `bytes`: from `address` to the end of that section | no section of that name → `noSuchRecord`; `address` outside every section of that name → `outOfBounds` |
| `rule` | `<id>@<version>` | `rule`: the registry descriptor | id not registered, or registered at another version → `noSuchRecord` |
| `proofCertificate` | `sha256:<64 lowercase hex>` | `certificate` | not in the certificate store → `noSuchRecord`; stored certificate not intact, or its hash ≠ the ref → `hashMismatch` |
| `signatureRecord` | `<corpus>/<record id>` | `record`, with no range: the bytes of the corpus record | the corpus lookup returns nothing → `noSuchRecord` |
| `analystAction` | `ann:<session>/<seq>` | `annotation`: the id of the annotation with that session and seq | no such annotation → `noSuchRecord` |
| `symbolGraph` | `<module>:<usr>` | `record`, with no range: the bytes of the symbol-graph record | the lookup returns nothing → `noSuchRecord` |

A section is *executable* when it is not zero-fill, and either has `S_ATTR_PURE_INSTRUCTIONS` set or is `__TEXT,__text`.

`LoadedBinary` does not keep:

* load-command offsets;
* section flags;
* `nlist` indices;
* unwind rows.

`NavigatorImageEvidence` therefore re-parses the selected slice once with `MachOParser`, with metadata recovery off, and the resolver reads from that. Callers resolving many entries build one evidence value and pass it to `resolve(_:in:context:)`.

## 4. The `proven` rule

**Validation (pure).** `NavigatorContractValidator.validateFact` refuses a fact with `status: "proven"` unless its provenance holds at least one entry with:

* `kind` exactly `proofCertificate`;
* `ref` of the form `sha256:` + 64 lowercase hex digits.

The reason reads `<at>.provenance: proven fact without a resolvable proof certificate`. The prefix `<at>` depends on where the fact appears:

* `fact` for `NavigatorFact.make` or `init(json:)`;
* `$` for `validateRecord`;
* `result.facts[<i>]` for `validateResult`;
* `state.facts[<i>]` for `validateState`.

This half needs no store, so the pure validator and its Python twin, `contract.py`, can apply it.

**Resolution (store).** `NavigatorContractValidator.certificateRefusal(for:certificate:)` takes a lookup from ref to certificate. It returns nil when one cited certificate meets all of these:

* it resolves;
* its stored hash equals the ref;
* it is intact;
* it concludes the fact's exact `subject`, `predicate` and `value`;
* it comes from the rule the fact's rule entry names: its `rule@ruleVersion` equals the fact's `rule@ruleVersion` (`NavigatorProvenance.ruleKey`, the key the fact id carries, from the first provenance entry with a `rule`); a fact with no rule entry accepts a certificate from any rule;
* it has outcome `proven`.

Otherwise it returns a refusal. The refusal code is the existing v1 `malformedInput`; v1 has no `invalidProvenance` refusal, and none is added. When the cited certificates fail for different reasons, the first row below that applies is reported.

| Case | Refusal |
|---|---|
| A matching, intact certificate from the fact's rule has an outcome other than `proven` | `malformedInput`, detail `proven fact whose proof certificate outcome is <outcome>` |
| A matching, intact certificate comes from another rule than the fact's rule entry names | `malformedInput`, detail `proven fact whose proof certificate is from <certificate rule@ruleVersion>, not <fact rule@ruleVersion>` |
| No cited certificate resolves, or a cited one has the wrong hash, is not intact, or concludes a different claim | `malformedInput`, detail `proven fact without a resolvable proof certificate` |
| The fact is not `proven` | none (nil) |

`NavigatorProofCertificate.supports(_:)` applies the same test to one certificate and one fact (intact, exact claim, the fact's rule when it names one, outcome `proven`).

Every refusal here has `retryable: false`. A store that persists facts calls `certificateRefusal` before it accepts a `proven` fact.

## 5. `proof.function-start-structural@1`

| | |
|---|---|
| Subject | `function:<entry>` (`kind: function`, `ref: <entry address>`, `image` when the slice identity is known) |
| Predicate, value | `isFunctionStart`, `true` |
| Premises (a) | `<entry>` lies in an executable section; the premise is that section's `section[<segment>,<name>]` header |
| Premises (b) | `<entry>` is 4-byte aligned (arithmetic; no record) |
| Premises (c) | At least one loader table lists `<entry>`, searched in this order: `functionStarts`, `exports`, `nlist` (`N_SECT`), `unwind`. Every hit that resolves is a premise, preceded by the record that holds its table: the `LC_FUNCTION_STARTS` command; the export-trie command (`LC_DYLD_EXPORTS_TRIE`, else `LC_DYLD_INFO[_ONLY]`) or `LC_SYMTAB` for a symbol-table export; `LC_SYMTAB`; the `__unwind_info` section header |
| Assumptions | `macho.slice-identity: the Mach-O load commands describe this slice` |
| Trusted base | `MachOParser`, `MachOUnwindFunctionStarts.resolvedRows`, `NavigatorProvenanceResolver` |
| Decoder | none |
| Registry | `producesStatus: proven`, `costClass: cheap`, `inputs: []`, `outputs: [isFunctionStart, boundaryUncertain]`, applicability `archs [arm64, arm64e]`, `platforms [macOS]`, `linkerFlavors [chained, classic]`, `onOutOfRange: abstain` |

The rule never yields `refuted`, because absence from the loader tables is not disproof. `run` polls for cancellation, and checks the optional wall-time limit:

* before the section lookup;
* before each table;
* after the last table.

The primitive result's budget is `{"bytes": <bytesRead>, "wallMillis": <wallMs>}`.

| Outcome | Primitive result |
|---|---|
| `proven` | `facts`: one `proven` fact. Its provenance is the rule entry, then the certificate entry, then the premises |
| `insufficientEvidence` | `narrowed`: no fact, and one frontier item with gap `boundaryUncertain`. Its `missingEvidence` lists what failed: `executableSection`, `alignment`, and the four table names when no table lists the address. The item names `derive.function-start-call-target` as the primitive to try next |
| `timeout` | Refusal `budgetExceeded`, `retryable: true`, detail `proof.function-start-structural@1 exceeded wallMillis <limit>`; no fact |
| `cancelled` | Refusal `cancelled`, `retryable: true`, detail `proof.function-start-structural@1 cancelled`; no fact |

Budget overrun maps to the v1 refusal `budgetExceeded`, and cancellation to the v1 refusal `cancelled`, both on the primitive result and both retryable. Neither is a frontier gap.

## 6. `derive.function-start-call-target@1`

This rule is not a proof. It applies when no loader table lists an aligned address in an executable section, but a direct `bl` reaches the address from a function whose `isFunctionStart` is `proven`. It then emits a `derived` fact:

* `tier: 2`;
* `derivedFrom`: one group per proven caller fact id;
* provenance: the rule entry, then one `decodedInstruction <bl address>` per call site.

It writes no certificate and never emits `proven`.

A caller qualifies only when its fact meets all of these:

* it is `proven`;
* it is `isFunctionStart = true`;
* it is about a `function` of the same image;
* it cites a well-formed certificate ref;
* its entry has a `FunctionSummary`.

The rule decodes the caller's bytes, clamped to its executable section, with `ARM64Decoder`. A call site counts only when all of these hold:

* its flow is `.call`;
* its branch target is the address;
* its decoded bytes equal the slice bytes;
* the raw word re-encodes as a `bl` to the same target.

| Case | Result |
|---|---|
| Unaligned, or not in an executable section | Refusal `preconditionFailed`: `<address> is not a 4-byte-aligned address in an executable section` |
| A loader table lists the address | Refusal `preconditionFailed`: `<address> is listed by a loader table; proof.function-start-structural applies` |
| No qualifying call site | `narrowed`: gap `boundaryUncertain`, `missingEvidence` `[functionStarts, exports, nlist, unwind, directCallFromProvenStart]` |
| One or more call sites | `facts`: the `derived` fact |

The budget is `{"instructions": <decoded>, "bytes": 4 × <decoded>}`. The trusted base is the proof's trusted base plus `ARM64Decoder`. The registry entry has `producesStatus: derived`, `costClass: bounded`, `inputs: [isFunctionStart]`, the same outputs and applicability, and `onOutOfRange: abstain`.

## 7. Worked example: `_loop_zero` in `UnwindLoops.dylib`

`MacScope/Tests/Fixtures/UnwindLoops.dylib` is a thin arm64 dylib. It has 14 load commands, image base 0, and chained fixups (`LC_DYLD_CHAINED_FIXUPS`). `_loop_zero` starts at `0x340`. Its image ref, `9f20e834-0ec1-31f0-aa9c-6153bbab70c6/e4957a86d91eb372`, is the slice identity that the fixture's existing oracle test records.

All four tables list `0x340`.

| # | Premise | Slice bytes | What it is |
|---|---|---|---|
| 1 | `section[__TEXT,__text]` | 104..<184 | The `section_64` header of the executable section holding `0x340` |
| 2 | `lc[11]` | 752..<768 | `LC_FUNCTION_STARTS` (dataoff 16688, datasize 24) |
| 3 | `functionStarts[0]@0x340` | 16688..<16690 | ULEB128 `c0 06` = 0x340 from base 0 |
| 4 | `lc[4]` | 504..<520 | `LC_DYLD_EXPORTS_TRIE` (dataoff 16432, datasize 256) |
| 5 | `exports[<i>]@0x340` | inside 16432..<16688 | The terminal-info bytes of `_loop_zero` in the export trie |
| 6 | `lc[5]` | 520..<544 | `LC_SYMTAB` (symoff 16712, nsyms 15) |
| 7 | `nlist[14]@0x340` | 16936..<16952 | The `N_SECT` symbol of `_loop_zero` |
| 8 | `section[__TEXT,__unwind_info]` | 184..<264 | The `__unwind_info` section header |
| 9 | `unwind[0]@0x340` | 1336..<1340 | The function-offset word of second-level entry 0 |

`<i>` is the index of `_loop_zero` in `MachOFile.exports`. Trie exports replace symbol-table exports of the same name, so `_loop_zero` appears once in that array, from the trie. The index and the terminal's exact range are read at run time; the test looks the index up by name.

`bytesRead` is the total size of the nine ranges: 80 + 16 + 2 + 16 + *t* + 24 + 16 + 80 + 4 = 238 + *t* bytes, where *t* is the size of the `_loop_zero` terminal.

The certificate, with the clock fixed at 0:

```json
{
  "assumptions": ["macho.slice-identity: the Mach-O load commands describe this slice"],
  "budget": {"bytesRead": "<238 + t, computed once at run time>", "wallMs": 0},
  "conclusion": "0x340 lies in executable section[__TEXT,__text], is 4-byte aligned and is listed by functionStarts, exports, nlist, unwind; isFunctionStart = true",
  "hash": "sha256:<computed once at run time>",
  "outcome": "proven",
  "predicate": "isFunctionStart",
  "premises": [
    {"kind": "loaderRecord", "ref": "section[__TEXT,__text]"},
    {"kind": "loaderRecord", "ref": "lc[11]"},
    {"kind": "loaderRecord", "ref": "functionStarts[0]@0x340"},
    {"kind": "loaderRecord", "ref": "lc[4]"},
    {"kind": "loaderRecord", "ref": "exports[<i>]@0x340"},
    {"kind": "loaderRecord", "ref": "lc[5]"},
    {"kind": "loaderRecord", "ref": "nlist[14]@0x340"},
    {"kind": "loaderRecord", "ref": "section[__TEXT,__unwind_info]"},
    {"kind": "loaderRecord", "ref": "unwind[0]@0x340"}
  ],
  "rule": "proof.function-start-structural",
  "ruleVersion": "1",
  "subject": {"image": "9f20e834-0ec1-31f0-aa9c-6153bbab70c6/e4957a86d91eb372", "kind": "function", "ref": "0x340"},
  "trustedBase": ["MachOParser", "MachOUnwindFunctionStarts.resolvedRows", "NavigatorProvenanceResolver"],
  "value": true
}
```

The hash input is this object without `hash` and `budget`, written with sorted keys and no whitespace. It begins `{"assumptions":["macho.slice-identity: the Mach-O load commands describe this slice"],"conclusion":`. The hash is SHA-256 over that text. It is computed once at run time and recorded in the handback; it is not reproduced here. Because `budget` is not hashed, *t* and the wall time do not enter it, and any later run on the same image reproduces it.

The fact that cites it, with toolchain `arm64/macOS/chained`:

```json
{
  "kind": "Fact",
  "schemaVersion": 1,
  "id": "f-<computed at run time from subject, predicate, value and proof.function-start-structural@1>",
  "subject": {"image": "9f20e834-0ec1-31f0-aa9c-6153bbab70c6/e4957a86d91eb372", "kind": "function", "ref": "0x340"},
  "predicate": "isFunctionStart",
  "value": true,
  "status": "proven",
  "provenance": [
    {"kind": "rule", "ref": "proof.function-start-structural@1", "rule": "proof.function-start-structural", "ruleVersion": "1"},
    {"kind": "proofCertificate", "ref": "sha256:<the certificate hash>"},
    {"kind": "loaderRecord", "ref": "section[__TEXT,__text]"},
    {"kind": "loaderRecord", "ref": "lc[11]"},
    {"kind": "loaderRecord", "ref": "functionStarts[0]@0x340"},
    {"kind": "loaderRecord", "ref": "lc[4]"},
    {"kind": "loaderRecord", "ref": "exports[<i>]@0x340"},
    {"kind": "loaderRecord", "ref": "lc[5]"},
    {"kind": "loaderRecord", "ref": "nlist[14]@0x340"},
    {"kind": "loaderRecord", "ref": "section[__TEXT,__unwind_info]"},
    {"kind": "loaderRecord", "ref": "unwind[0]@0x340"}
  ],
  "toolchain": "arm64/macOS/chained",
  "revert": "revert:<id>"
}
```

The primitive result is `facts`, with budget `{"bytes": 238 + t, "wallMillis": 0}`.

Contrast `0x4e8`, the first byte of `__TEXT,__unwind_info`:

* no executable section holds it;
* no table lists it.

The run ends `insufficientEvidence`. The result is `narrowed`, with one `boundaryUncertain` item whose `missingEvidence` is `[executableSection, functionStarts, exports, nlist, unwind]`.

Resolving `decodedInstruction 0x340` gives slice bytes 832..<836, the first instruction of `_loop_zero`. Resolving `decodedInstruction 0x4e8` gives `noSuchRecord`, because `__unwind_info` holds no instructions.
