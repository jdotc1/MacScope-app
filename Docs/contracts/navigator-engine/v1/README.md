# Navigator–engine contract v1 (N0)

This directory contains the navigator-engine contract and worked examples. Status as of 2026-10-22:

* The Python reference and the Swift port agree on every generated case (§6).
* The Swift sources compile on Linux Swift 5.10 with `-strict-concurrency=complete -warnings-as-errors`.
* **Not compiled with Xcode 27, not wired into persistence, not run in the app.**

## 1. Files

| file | role |
|---|---|
| `navigator-engine.schema.json` | JSON Schema (2020-12) for the five record kinds: `Fact`, `FrontierItem`, `PrimitiveResult`, `Annotation`, `NavigatorEngineState` |
| `vocabulary.json` | closed vocabularies: statuses, subject kinds, predicates (value shape, `multi`), gaps, refusal codes, provenance kinds, annotation actions and authors. Append-only within v1 |
| `examples/` | worked examples (§7) |
| `swift-differential.json` | latest Swift-vs-Python differential result |
| `MacScope/Services/NavigatorContract/*.swift` | Swift port, listed in `MacScopeAnalysisCore` |

## 2. Values, canonical encoding and ids

* **Values.** Values are JSON without floating-point numbers. Integers must fit in Int64. Every object key, at any depth, is an ASCII identifier (`[A-Za-z_][A-Za-z0-9_]*`).
* **Canonical encoding.** This is `json.dumps(v, sort_keys=True, separators=(",",":"), ensure_ascii=False)`:
  * keys are sorted by code point;
  * only `"`, `\` and C0 controls are escaped, with `\u00xx` in lowercase hex;
  * the Swift encoder reproduces it byte for byte.
* **Comparison.** Values compare by canonical bytes, i.e. exact Unicode scalars. Swift `String ==`, `Set<String>` and dictionary keys use canonical equivalence (NFC "é" equals NFD "é"), so the Swift code never compares contract strings that way. The differential found exactly this defect in the first port.
* **Ids.** Each id is the prefix, a hyphen, then the first 32 hex digits of SHA-256 over the canonical bytes of:

  | record | prefix | hashed fields |
  |---|---|---|
  | Fact | `f` | `[subject, predicate, value, ruleKey]` |
  | FrontierItem | `g` | `[subject, gap, detail]` |
  | Annotation | `a` | `[session, seq, author, action, subject, predicate, value, sorted(cites)]` |

  `ruleKey` is `rule@ruleVersion` of the first provenance entry that names a rule, or empty if none does. The same fact from the same rule therefore has the same id, whichever evidence reference produced it.
* **Revert handles.** Every fact and annotation carries `revert: "revert:<id>"`.
* **Strict reader.** The Swift reader refuses floats, out-of-range integers, lone surrogates, raw control characters and nesting deeper than 256. Python applies the same gate (`strict_json`) before validating.

## 3. Record rules beyond the JSON Schema

* `tier` (1–3) is present exactly when the status is `derived` or `candidate`.
* `derived` requires `derivedFrom`, which is a list of alternative premise sets. Each set is a conjunction of fact ids.
* `authoritative` facts are read from the image and never carry `derivedFrom`.
* `unknown` facts carry `null`.
* `candidate` facts carry `{"alternatives": [...]}` with at least two distinct values.
* Every predicate is in the vocabulary, and its value has the declared shape (`nominalKind` is one of class, struct, enum, protocol).
* A navigator annotation cites at least one fact and states a rationale. An analyst annotation may cite nothing.
* Every id is recomputed and must match.

## 4. State rules

`NavigatorEngineState` persists:

* every fact, including facts no longer live;
* `reverted`, the ids of reverted facts;
* the current frontier;
* every accepted annotation, with its `reverted` flag.

The state rules:

* There are no duplicate ids and no derivation cycles.
* A `derived` fact never rests on a `candidate` or `unknown` premise that is present.
* Reverted ids name persisted, non-authoritative facts.
* Frontier blockers exist.
* **Dangling references are dead, not invalid.** Undoing one session can remove facts that another session built on, so:
  * a derivation whose premise is absent does not hold;
  * an annotation whose citation is absent is *stale*: it is never displayed and is reported as a `staleAnnotation` frontier item.

  This rule was settled after the differential found persisted states failing their own validation.
* `Store.from_state(state())` reproduces the observable view exactly. Journal history itself is not persisted.

## 5. Store semantics

The store holds base facts plus an append-only journal of operations: `result`, `accept` and `revert`, each tagged with a session. Every view is a pure function of these two.

* **Live facts.** Facts minus reverted ones. Then, repeated to a fixed point, every fact none of whose premise sets is fully live is removed too. "Everything derived only from it" is therefore exact: a fact with a surviving alternative derivation stays.
* **Display precedence** for (subject, predicate), highest first:

  | rank | source | how ties and disagreements resolve |
  |---|---|---|
  | 1 | authoritative | disagreeing values are shown with a conflict flag |
  | 2 | analyst | the latest by (seq, id) wins |
  | 3 | **proven** | disagreeing values are shown with a conflict flag |
  | 4 | navigator | disagreeing values are shown with a conflict flag |
  | 5 | derived | the highest tier wins |
  | 6 | candidate | the alternative set, always marked as a conflict |
  | 7 | fallback | nothing to show |

  The contract text omitted `proven`. It is placed directly below the analyst.
* **Multi-valued predicates** (`callsTarget`, `storedField`, `enumCase`, `conformsTo`) show the union of values instead of a conflict.
* **Refusals.** Operations return a typed refusal instead of free text:
  * `malformedInput`: the record fails validation, or the revert handle is malformed.
  * `unknownFact`: an annotation cites a fact that is not live, a result derives from a missing fact, or a revert names a target that is not live.
  * `conflictsWithAuthority`: a navigator annotation contradicts an authoritative or proven fact. The analyst may override it; the navigator may not.
  * `notReversible`: a revert targets an authoritative fact.
  * `preconditionFailed`: an annotation is accepted twice, or a derived fact rests on a candidate.
  * A primitive's own refusal is returned unchanged.
* **Store-raised frontier items.** The frontier includes base and result items whose blockers are live, plus three kinds the store raises itself:
  * `conflictingFacts`, when live authoritative, proven or derived facts disagree on a single-valued predicate;
  * `conflictingAnnotations`, when live navigator annotations disagree;
  * `staleAnnotation`, when an annotation's citation is gone.
* **Undo.** `undoSession(s)` drops all of `s`'s journal entries. The observable snapshot then equals the snapshot before `s` began; this is tested on random sessions in both languages.
* **Bounded journal (revision 1.1).** The journal keeps at most 1,024 entries (`journalBound`, `JOURNAL_LIMIT`). When it would exceed that, the oldest entry folds into the base (facts merge by id, frontier items append once, accepts and reverts become base annotations and base reverts). Every view is unchanged by a fold. `undoSession` of a session with a folded entry is refused with `notReversible`.
* **Equal facts union their provenance.** Two records with one id are one fact: the first record stays, provenance entries are unioned by canonical bytes in first-seen order, and the newer `generation` and `dependsOn` win.
* **Annotation premises.** A `derivedFrom` group may name an accepted annotation as `ann:<session>/<seq>`; live facts and live annotations are a joint fixed point.
* **Stale marks.** `markStale(ids)` takes facts out of the live view until a producer re-asserts them; `markStaleGeneration(changedFacets:)` marks every live fact whose `dependsOn` meets a changed fingerprint facet. Annotations citing a stale fact are stale and raise `staleAnnotation`. Stale marks are not part of the persisted v1 record; the workspace envelope carries them beside it, and `init(state:staleGeneration:)` applies them before the restore reconciles the persisted frontier.
* **`conflictingFacts`.** Competing single values among live authoritative, proven or derived facts on a non-multi predicate raise a store-raised `conflictingFacts` item blocked by those facts, with primitive `revert`.
* **Restore.** `init(state:)` starts with an empty base frontier, replays accepts and reverts, applies the stale marks, and keeps as base only the persisted frontier items it did not regenerate itself, so a store-raised item is never shown twice and the rest of the persisted frontier is preserved byte for byte.
* **Revert preview.** `preview(revert:)` reports what a revert would change (facts, annotations, frontier) on a copy; the store is untouched.

## 6. Verification (Linux, 2026-10-22)

* **H18 parity.** On 400 random H18 naming states (more than 2,000 functions), the generic contract fed H18 results displays exactly what `h18_known_library/project.py` `effective_name` displays.
* **Swift differential** (`swiftdiff.py --records 50000 --sessions 3000`, Swift 5.10.1 Linux, CryptoKit SHA-256 shim): **0 mismatches**.
  * **Vocabulary:** identical.
  * **Records:** 50,000 texts. 4,547 were valid, 31,017 invalid and 14,436 were refused by the reader. Swift and Python agreed on parse, validity and canonical bytes for every one.
  * **Sessions:** 3,000 sessions with 25,191 operations. Swift and Python agreed on every refusal code, snapshot and persisted state's canonical bytes. 0 persisted states were invalid and 0 round-trips failed.
* **Defects the differential found and fixed:**
  * Swift canonical-equivalence comparisons (§2);
  * a derived fact accepted on a candidate premise;
  * persisted states with dangling references (§4);
  * Python crashes on unhashable `kind` and `predicate` values;
  * Python `$` regex anchors accepting a trailing newline.

**Not covered:**

* Xcode 27 or Swift 6 language mode on the Mac;
* Apple Foundation;
* persistence wiring (U03 persistence single writer);
* MCP exposure (N3).

## 7. Worked examples

* `examples/n1-fixture.state.json`: N1's Swift metadata output for the fixture module, as 76 authoritative facts.
* `examples/h18-demo.state.json`: the H18 synthetic demo.
  * Exact and LOH-rewritten matches become derived `libraryIdentity` facts plus a derived `hasName`.
  * The static-twin probe becomes a candidate `libraryIdentity` plus an `ambiguousLibraryIdentity` frontier item.
  * An export stays authoritative.
  * An analyst rename wins.
* `examples/navigator-session.json`: a scripted session showing each step's outcome, display and frontier. The steps are:
  * a primitive result;
  * a navigator rename, then a rival rename, which produce a conflict;
  * a navigator type proposal refused with `conflictsWithAuthority`;
  * an analyst override, then its revert;
  * a revert of a proven premise, which cascades and makes annotations stale;
  * a revert of an authoritative fact, refused with `notReversible`;
  * a session undo, which restores the snapshot.

## 8. Subject grammar and toolchain key (v1.1 proposal)

**Terms adopted as revision 1.1; grammar still proposed.** The four predicates (`methodTableEntry`, `conformanceMethod`, `metadataAccessorOf`, `pointerAuthKey`) and three gaps (`conflictingFacts`, `budgetExceeded`, `producerIncomplete`) are appended to `vocabulary.json` (append only; `schemaVersion` stays 1), and records may carry an optional `generation` and `dependsOn`. The subject-ref grammar is not adopted: `validateRecord` still accepts any non-empty ref, and the grammar keys stay in `vocabulary.v1.1-proposed.json` (`subjectRefGrammar`, `provenanceRefGrammar`). The Swift side lives in `MacScope/Services/NavigatorContract/` beside the v1 port:

| file | role |
|---|---|
| `NavigatorSubjectRef.swift` | canonical constructors for `subject.ref` and `subject.image`; `parse(_:kind:)`; opt-in `NavigatorContractValidator.validateCanonicalRefs(_:)`, not called by `validateRecord` |
| `NavigatorToolchainKey.swift` | `NavigatorToolchainKey` and `NavigatorToolchainKeyDetector.detect(file:identity:)` |
| `NavigatorPrimitiveRegistry.swift` | primitive and knowledge-catalogue descriptors with cost and applicability; `validateAgainstVocabulary()` |
| `NavigatorKnowledgeVersion.swift` | digest over rule and catalogue `id@version` pairs, engine identity and decoder version |
| `NavigatorAnalysisInputKey.swift` | content-addressed analysis input key, stored as the optional `inputKey` of an analysis fingerprint |
| `NavigatorProofCertificate.swift` | the proof certificate record (`make`, `parse`, content `hash`, `supports(_:)`); a `proven` fact cites one by `sha256:<hash>` |
| `NavigatorProvenanceResolver.swift` | `NavigatorProvenanceRef` (the provenance-ref grammar), `NavigatorImageEvidence` and `NavigatorProvenanceResolver`, which resolve a ref to the bytes it names |

The certificate record, its hash, the provenance-ref grammar with its resolution table, the rule that every `proven` fact must cite a resolvable certificate, and the two first rules that produce certificates (`proof.function-start-structural@1`, `derive.function-start-call-target@1`) are specified in `proof-certificate.md`. `validateRecord` checks the form of the ref; the workspace resolves it against the certificates its producer retained and drops a `proven` fact whose certificate does not resolve.

### 8.1 Subject refs

Every builder emits one canonical spelling. `parse` accepts exactly that spelling and returns nil for anything else; it never normalises or guesses.

| subject kind | ref grammar | builder |
|---|---|---|
| `image` | `<uuid>/<sliceSHA256 prefix16>`; the UUID is lowercase, `nouuid` when the slice has no `LC_UUID` | `imageRef(_:)` |
| `address` | `0x<lowercase hex, no leading zeros>` (`0x0` for zero) | `address(_:)` |
| `range` | `<address>..<<address>`, half-open, lower ≤ upper | `range(_:_:)` |
| `function` | `<address of entry>` | `function(entry:)` |
| `type` | `<descriptor address>` | `type(descriptor:)` |
| `protocol` | `<descriptor address>` | `protocol(descriptor:)` |
| `metadataRecord` | `<section>@<address>` | `metadataRecord(section:address:)` |
| `selector` | `<selector string>` (no whitespace or control characters) | `selector(_:)` |
| `viewBody` | `<address of body getter>` | `viewBody(getter:)` |
| `field` | `<type ref>#<field index>` | `field(typeRef:index:)` |
| `field` (legacy) | `<type ref>.<field name>` | `field(typeRef:name:)` |
| `type`, `protocol` (legacy) | `name:<qualified name>` | `named(kind:qualifiedName:)` |

The two legacy forms are the ones the Swift metadata projection emits today: `name:` for a conforming type or protocol whose descriptor is not in the image, and `<type ref>.<field name>` for stored fields and enum cases. A `<type ref>` inside a field ref is a descriptor address or the `name:` form. A field name may not contain `.` or `#`, so a field ref splits unambiguously at its last `#` (index form) or last `.` (name form).

Provenance refs (`provenanceRefGrammar`):

| provenance kind | ref grammar |
|---|---|
| `loaderRecord` | `lc[<n>]`, `section[<segment>,<name>]` or `<table>[<i>]@<address>` |
| `decodedInstruction` | `<address>` |
| `metadataRecord` | `<section>@<address>` |
| `rule` | `<rule id>@<version>` |
| `proofCertificate` | `sha256:<hex>` |
| `signatureRecord` | `<corpus>/<record id>` |
| `analystAction` | `ann:<session>/<seq>` |
| `symbolGraph` | `<module>:<usr>` |

### 8.2 Toolchain key

`NavigatorToolchainKeyDetector.detect(file:identity:)` reads the slice's load commands and sections. The Mach-O loader keeps every `LC_BUILD_VERSION` in `MachOFile.buildVersions`, in load-command order; `buildVersion` remains the last of them. It also keeps every `LC_VERSION_MIN_*` in `legacyMinimumOSVersions` in load-command order, while `legacyMinimumOSVersion` remains the last record.

| field | content |
|---|---|
| `arch` | the slice architecture variant: `arm64`, `arm64e`, `x86_64`, `x86_64h` or `other` |
| `platforms` | `{name, minOS, sdk}` for every `LC_BUILD_VERSION`, then every `LC_VERSION_MIN_*` record, preserving load-command order within each array |
| `tools` | `{name, version}` from the `LC_BUILD_VERSION` tool records (`clang`, `swift`, `ld`, `lld`, `tool <n>`), de-duplicated in order |
| `swiftABI` | `"5"` when any `__swift5_*` section is present, otherwise absent |
| `linkerFlavor` | `chained` (`LC_DYLD_CHAINED_FIXUPS`), `classic` (`LC_DYLD_INFO[_ONLY]`) or `none` |
| `confidence` | `exact` when at least one `LC_BUILD_VERSION` carries tools; `partial` when there is only `LC_VERSION_MIN_*` or no tools; `unknown` when there is neither |
| `derivedFrom` | the selected-slice SHA-256 |
| `canonical` | `toolchain-key/1\|arch=…\|platforms=…\|tools=…\|swiftABI=…\|linker=…\|confidence=…`, every field except `derivedFrom`; the opaque `toolchain` string of a record |

`unknown` is a value, not an error. A rule whose applicability cannot be evaluated against the key raises `unsupportedToolchain` for the image. The key reserves no slot for `__objc_imageinfo`, which nothing parses yet.

### 8.3 Registry, knowledge version and input key

* **Registry.** Each primitive declares `id`, `version`, `producesStatus`, `costClass` (`cheap`, `bounded` or `expensive`), `inputs` and `outputs` (vocabulary predicates or gaps), `applicability` (`archs`, `platforms`, `swiftABI`, `linkerFlavors`, and for generated knowledge `swiftTools`), `onOutOfRange` (`abstain`, `downgrade` or `proceed`) and `isImplemented`. Knowledge catalogues declare `id`, `version`, `applicability` and `onOutOfRange`. The seed lists `macho.slice-identity`, `macho.build-version`, `macscope.swift-metadata-parser`, `objc.class-parser`, `proof.function-start-structural` (declared, not implemented), `signatures.call-catalog`, `analysis.no-return-catalog` and `signatures.swift-runtime-seeds` (swift tools 6.0–6.3, `downgrade` outside).
* **Knowledge version.** SHA-256 over sorted primitive and catalogue `{id, version}` pairs, with each component separately length-prefixed, the engine identity and the decoder version.
* **Analysis input key.** `H(sliceSHA256 ‖ selectedSliceIndex ‖ patchOverlayDigest ‖ analyzerStamp ‖ knowledgeVersion ‖ structuralOverridesDigest)`, each component length-prefixed. `AnalysisFingerprintBuilder.fingerprint(binary:analysis:navigatorContext:)` stores it in the fingerprint's optional `inputKey`. It never feeds `overallSHA256` or a facet, so the overall digest is the same with and without a context. Fingerprints built without a context have no `inputKey` and keep their encoded shape.

The slice-identity, build-version, Objective-C class and structural-proof primitives are declared with `isImplemented: false`; only the Swift metadata projection has a producer. Existing subject construction in that projection migrates separately. Tool versions retain the loader’s numeric representation; Swift sections alone do not establish a compiler release, and a missing Swift tool record leaves constrained applicability undetermined.
