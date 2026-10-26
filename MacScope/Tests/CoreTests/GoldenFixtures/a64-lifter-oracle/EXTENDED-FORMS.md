# Extended A64 oracle fixtures

`extended-forms.json.gz` is a losslessly compressed copy of the returned
`fixtures/upcoming-forms.json`; its schema matches the existing oracle loader.
All original metadata, inputs and expected state are retained.

1,656 vectors / 111 forms: SQXTUN 108, SQRDMULH 264, DUP 436, MVNI 128,
ST3 360 and LD4 360. The embedded provenance describes QEMU 11.0.2 / LLVM 21
and source revision 12664d24cb8fdb9902acbd4048deb9260e9a829e. These are upstream
execution claims, not a new local QEMU run.

`A64LifterOracleTests.testExtendedFormsAgainstMacIR` uses the existing evaluator
to compare modeled GPR/SP/PC/vector/memory state and emits
`extended-forms-report.md` and `extended-forms-results.json` under
`MACSCOPE_A64_ORACLE_REPORT`, or the temporary directory when unset.
It does not prove unchanged FPCR/NZCV/FPSR state. Explicit expected FPSR or
unsupported vector-element semantics remain nonpassing outcomes. The original
9,368-vector baseline is unchanged.

The test requires zero numeric FAIL and zero HARNESS outcomes, and at least
409 PASS, the previously recorded floor. UNLIFTED and UNSUPPORTED outcomes
are reported as coverage gaps and never counted as passes. The PASS floor
may only be raised. No evaluator or MacIR changes accompany these fixtures.
