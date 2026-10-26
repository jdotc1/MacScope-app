# RX-17 semantic harness

`rx17_semantics.py` invokes the vendored `sleigh-lift` process against the supplied compiled language files. It does not install or import pypcode. It uses byte-addressed registers and unique storage, endian-aware overlapping architectural register and unique-temporary views, bounded relative p-code branches, integer operations and FP16/FP32/FP64 operations. Unknown operations fail closed.

Example:

```
python3 rx17_semantics.py --tree /absolute/compiled/tree --lifter /absolute/package/bin/sleigh-lift --pspec /absolute/bridge.pspec --suite all --report /absolute/report.json
```

`--languages` can override the default `TREE/Ghidra/Processors/AARCH64/data/languages`. `--variant le --variant be --variant apple` selects variants (all by default). `--suite fj|fhm|bf16|all` selects a family. Tests use the actual emitted p-code; reports record compiled `.sla` SHA-256. The harness caches lifted words for its process lifetime.

Expected cases per variant: FJCVTZS 384; FHM 576; BF16 3456. FJ covers signed zeros, exact/fractional inputs, signed range and modulo boundaries, infinities/NaNs, subnormals, FZ/AH/FIZ, WZR, NZCV, X-upper clearing and prior FPSR. FHM covers two/four lanes, lower/upper parts, add/subtract, vector/indexed (all eight indices), destination/source aliases and binary16 maximal finite products. BF16 covers scalar and both narrowing forms, aliasing, all rounding modes, AH/DN/FZ/FIZ/NEP, signed zero, tie parity, finite limits, infinities/NaNs and tiny values.

The only admitted CALLOTHER contract is `ARM64FPProcessExceptions(exceptions:8, fpcr:8, oldFPSR:8) -> newFPSR:8`. The normal-path callback returns sticky union; trap-enable bits reject execution. Conversion and accumulation arithmetic must be emitted explicitly, not supplied by the callback. Numeric checks do not prove actual FP trap handling, native MacScope acceptance, streaming-mode behavior, or FHM exceptional/FPCR rounding semantics. FHM checks are ordinary finite round-to-nearest values, for which binary16 multiplication is exact in binary32.

Oracle basis: packaged research recipes plus pinned Sail `FPConvertBF`, `FPRoundBase`, and `FPToFixedJS`, at `rems-project/sail-arm` commit `1bf2e5574ba9d704639a28401b6a387dcb113cae`. Independently written Python bit/rational logic; no Sail implementation copied. Eleven interpreter mechanical checks passed before instruction execution, covering both endian register overlap, relative forward/backward branches, finite widening/product, JS modulo and BF16 tie parity. The executed results are summarized in ../RX17_VALIDATION.json.

BE harness correction: the actual compiler emits an 8-byte unique temporary at offset 0x178400 and reads its low 32 bits at 0x178404. Unique space therefore uses big-endian byte order in the BE language too. The original failed BE receipt is preserved separately; only BE is rerun after this harness correction.

Corrected BE execution passed: FJCVTZS 384, FHM 576, BF16 3,456 (4,416 total), 33.64 seconds wall time (12.42 user / 3.09 system). Receipt: `isa-integration-20261012.noindex/semantics-be-corrected.json`. Compiled BE SLA SHA-256: `750d8836a9043a362fd47410e66af2f60ab953522a40a3810c1c66fd557339cd`. `test_vm_storage.py` adds the observed 0x178400/0x178404 overlap regression and passes both byte orders. Parent owns the previously passing LE/Apple receipts; this correction did not rerun them or rebuild any source.

`rx17_dataflow.py` runs 546 cases per variant (1,638 total), asserting opaque helper arguments, pair selection, aliases and output clearing. Its helper returns a sentinel; this is not numerical semantics. All three variants passed in 85.543 seconds. Use the same --tree/--lifter/--pspec options as the semantic harness.

## Fixed native acceptance handback

`rx17_native_acceptance_vectors.json` contains eight fixed scenarios for the build-root-owned provider acceptance: indexed BFDOT/SUDOT/USDOT (including an alias), three FCMLA element/pair forms, FJCVTZS and scalar BFCVT. Instruction bytes and raw helper widths are explicit; the six dataflow scenarios include deterministic initial register bytes and expected helper inputs using the existing harness formula. Register strings are least-significant-byte first, not target-endian storage images.

This is prepared test input, not an executed native receipt. Optimized provider output may require following SSA definitions rather than matching raw argument shapes. The DTO does not expose a generic FP-effect flag; assert named-call preservation and dependencies without claiming trap semantics or parsing pseudocode. Native adapter/acceptance, package admission and governance remain with build root. Existing semantic receipts are reused. Do not rerun a corpus, cache scan, random sweep or broad numeric harness to consume this fixture.
