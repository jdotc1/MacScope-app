# CP17 reconciled findings from saved evidence

Audit date: 2026-10-13. This supplement corrects documentation only. It does not replace or alter original receipts, frozen ZIPs, sources, findings files or correction ledgers. No compiler, DWARF parser, fixture generator, reduction, mutation or reader execution occurred in this audit.

## 1. Confirmed mechanism: CU-root indexed attributes resolved before their bases

The fourth-pass reduced witness and causal control establish one actual wrong-recovery mechanism in the pinned complete DWARFDIETree reader. Both reduced inputs were admitted by LLVM, independently traversed by pyelftools 0.32 and passed to the actual reader before the later interruption.

- Witness: fourth-pass/minimized/cu-root-indexed-before-bases/.
- Reduced ELF SHA256 (saved witness receipt): 30a296a91fe78c8093806faed69591d66f998dd5e2f8e325a7b4856ba5c22e4e.
- Independent expected CU name: entry.c. Observed: left/unit.c.
- Independent expected low_pc: 0x401030. Observed: 0x402000.
- Control: fourth-pass/minimized/cu-root-bases-before-indexed-control/. It preserves the same attribute values and linked tables but places the base attributes first; both values recover correctly.
- Each contains one CU and one DIE, with 448 bytes of retained debug sections. This is minimum nonempty DIE count, not a claim of byte-global minimality. Linked allocated-section addresses/bytes were checked unchanged in the executed reduction.
- Product source: DWARFDIETree.swift:137–138 initializes bases to 8; lines185–214 consume and resolve attributes in abbreviation order; lines393–403 eagerly resolve indexed strings. A root indexed attribute preceding its own base can therefore use the wrong contribution. Address resolution has the same temporal dependency.
- Repair direction, not a production patch: preserve indexed root values until the current CU's base attributes are available, then resolve against that CU. Do not solve the issue by assuming a fixed table contribution or changing compiler truth.

The original witness IDs incorrectly say compile.log because a loop variable shadowed the case name. WITNESS-ID-CORRECTION.json in the recovered archive maps directory identity to the intended IDs without rewriting raw receipts. This metadata error does not invalidate the independent values, successful admission or recorded executions.

### Associated corpus observations

The 144 original candidate assertions are 72 CU-name and 72 low-PC disagreements on later Clang DWARF5 multi-TU roots. They are associated with this now-confirmed mechanism. They remain individual corpus observations; the focused witness does not turn them into 144 distinct bugs or prove that every possible producer/form combination has been minimized. The confirmed count is one mechanism with two observable field failures.

## 2. Eight unresolved range-base cases

Eight corrected assertions recover zero-based range pairs instead of independently expected CU-base-adjusted ranges. Example gcc-d5-O1-multiple-f06 expects [0x401000,0x401006) and [0x40100c,0x40100f), but observation contains [0,6) and [12,15). Source DWARFReader.swift:1861 initializes a range base to zero; lines1902–1907 apply offset pairs.

These remain source-attributed, unconfirmed range-base cases. The attempted fourth-pass reduction reached LLVM admission/dump but then failed the allocated-section equality check before reference extraction or product execution. The script removes .eh_frame while checking all allocated sections for preservation. There is no completed reduced product observation, explicit-base control or valid two-arm mechanism proof for this candidate.

Do not reuse that failed attempted reduction as a successful fixture. Preserve the failure. A future modified reduction must retain all allocated sections and keep the equality assertion; it must not weaken or bypass the validator.

## 3. Unsupported projections and presentation differences

Corrected non-signature producer results contain 646 DOCUMENTED_UNSUPPORTED assertions. They must not be counted as recovered semantic facts or bugs:

- 156 CU names encoded with DW_FORM_line_strp are explicitly skipped by DWARFDIETree.swift:353–358.
- 52 location-list comparisons initially equated absolute addresses with intentionally raw offset pairs. DWARFReader.swift:1649–1652 documents the raw projection. Every saved observation matches the independently derived relative pair; no implicit base repair is warranted merely to make the DTO look absolute.
- 24 function-name omissions inherit names through specification, outside the existing direct name+address recovery path.
- 24 optimized local-list omissions inherit their names through origins; recoverLoclists requires a directly named node. Eight also contain only empty intervals, which the hi>lo filter excludes. Absence alone is not a product defect.
- The other unsupported assertions retain previously recorded v4-list/local-availability limitations; see exact ledgers rather than inferring support from an aggregate count.

Corrected signature results contain 364 DOCUMENTED_UNSUPPORTED assertions: 294 absent return-type projections, 42 qualifier/declarator-binding ambiguities, 16 parameter-name fallback projections and 12 empty-evidence signature omissions. The 12 omissions are _start in the single-TU C++ family, with no emitted type/formal/prototyped/variadic evidence in the reference representation. The reader intentionally excludes empty overrides. They are not demonstrated wrong recovery. However, the independent reference's handling of implicit C++ prototype semantics still needs review before claiming exhaustive source-language truth.

## 4. Terminal-row comparisons excluded at the field level

All 134 historical line candidates differed only in isStmt on end_sequence rows. DWARF4 §6.2.2 p110 and DWARF5 §6.2.2/Table6.3 p151 state that other information on a terminal row is not meaningful. The correction excludes those nonmeaningful fields only. Terminal address/end_sequence and all compared nonterminal state remain checked. Consequently, 134 case-level line comparisons become PASS; no entire line sequence was dropped and no product output became the oracle.

Specs used in the already-completed audit:
- https://dwarfstd.org/doc/DWARF4.pdf#page=124
- https://dwarfstd.org/doc/DWARF5.pdf#page=169

## 5. Malformed-input labels corrected

The historical set has 124 derivatives, not 124 independently established structural errors:

- 100 structural derivatives were rejected by LLVM and executed under the earlier TWO-reader profile.
- 12 cyclic-type-graph probes were accepted by LLVM and remain a separately qualified semantic/pathology category.
- 12 expression_truncation recipes actually altered the final byte of a complete DW_OP_addr operand. Their malformed label is wrong; they are excluded from malformed coverage. Raw receipts and successful bounded-process observations remain unchanged.

There was no four-reader malformed execution. Existing normal exits show observed bounded completion only, not complete semantic rejection or fail-closed conformance.

## 6. Counts and qualification

Saved corrected producer totals: 32,354 PASS assertions, 1,010 DOCUMENTED_UNSUPPORTED assertions, 152 associated/candidate assertions and six quarantined verifier-disagreement assertions. Of the 152, 144 are associated with the confirmed CU-root mechanism; eight remain unresolved range-base cases. These are assertion counts, not distinct bugs. PASS includes DTO identity checks and must not be described as that many independent type/signature semantic facts.

Six Clang DWARF5 qualifier-family inputs remain quarantined LLVM string-offset verifier disagreements. Independent traversal succeeded, so quarantine must not be described as proof of malformed producer output.

All four unchanged readers did execute on the 306 admitted linked corpus, across separately recorded passes. A completed CP17 acceptance claim is still premature: consumer/patch, remaining mechanism minimization, sensitivity tests and several field-coverage assertions are unfinished. No local macOS acceptance occurred.
