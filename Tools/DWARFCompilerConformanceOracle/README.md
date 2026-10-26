# CP17 saved-witness consumer supplement v1

This adds one bounded XCTest class and copies two existing admitted section reductions, without generating a new binary input. All product readers/models/old tests remain unchanged. No compiler/parser/reduction/mutation/corpus execution occurred while authoring this supplement. The test source has not been typechecked, built or executed.

## Exact scope

The fixture pair independently expects CU name entry.c and linked low_pc0x401030. Saved original reader execution returns left/unit.c/0x402000 for indexed-before-bases, and correct values for the base-first control. The new regression intentionally asserts independent correct values. It is not wrapped in XCTExpectFailure, skipped, or given a fabricated passing baseline.

Fixture files are unchanged copies of existing section bytes. Visible *.bin filenames only replace original hidden .debug_* filenames for resource packaging; FIXTURE-MAPPING.json records exact mapping, identities and stored hashes. saved-evidence/ retains original ELF, source, command/LLVM/probe/reference receipts. The known raw witness id compile.log remains intact there; PROVENANCE.json supplies the corrected directory-based identity.

## Future local selectors, not executed here

- CoreTests/DWARFCompilerConformanceOracleTests/testIndexedCURootAttributesUseTheirOwnLateBases
- CoreTests/DWARFCompilerConformanceOracleTests/testBaseFirstCURootControl

Expected at pinned c5017731d7f23bbe37559e3d61eaf0c1bb04178b, inferred from saved reader output rather than an XCTest run: first selector fails its two value assertions; control passes. Actual newly authored XCTest runs:0. A genuine red regression is deliberate, not an acceptance failure to suppress.

Local owner must review the patch, confirm current-new-path availability and add the new Swift file to CoreTests if the repository's source discovery does not include it automatically. The consumer first reads GoldenFixtures/dwarf-compiler-conformance relative to its source file, so normal source-checkout focused tests need no project-resource edit. If tests are packaged without source files, include that folder as a folder resource preserving its two fixture subdirectories; Bundle lookup is the fallback. No project.yml/project-file change is in this patch. No existing selector rerun is requested for confidence.

Do not execute the cloud harness scripts on the Mac. No production fix, broad campaign, macOS build/acceptance, signing or reservation change is included. Existing local guardrails and receipt reuse still apply. Precise station/build invocation belongs to the local owner; the selectors above are the bounded intended scope.

## Four-reader reconciliation and remaining work

All four readers have saved valid-corpus execution evidence from prior passes; the official Crypto dependency gap was resolved. The adjacent FINDINGS-RECONCILED.md and COMPLETION-PLAN.md are the pre-consumer evidence-only audit. This supplement fills their consumer-authoring/patch gap only: compilation/execution of the new tests remains unverified. One CU-base mechanism has valid witness/control; eight range-base assertions remain unresolved, comparator sensitivity and wider source-path/type/location coverage remain unfinished. This is not complete CP17 acceptance.
