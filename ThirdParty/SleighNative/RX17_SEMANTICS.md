# RX-17 AArch64 repair contract

These MacScope changes retain the immutable lifting-bits/sleigh v12.1.2 package
and its archive manifest. `PATCHED_RESOURCES.json` separately binds the ordered
patches, the 26-file resource closure, and the overlaid runtime package. Source
replay is exact with zero patch fuzz; all three `.sla` outputs come from the
pinned vendored compiler. The Git LFS pointer for `libdecomp.a` is the canonical
artifact identity when calculating package records.

## Implemented behavior

- Dot-product indexed operands export the selected 32-bit group, preventing the
  previous lifter crash. BFDOT, USDOT and SUDOT retain old destination inputs;
  active vector widths and upper clearing are explicit. Dot indexing is separate
  from the generic lane selector to avoid changing unrelated constructors.
- RMIF rotates before selecting NZCV and preserves unmasked flags. CSSC W forms
  clear the upper X bits. FHM and BFMLAL indexed operands select the encoded lane.
- FJCVTZS emits bit-level JavaScript conversion modulo 2^32, clears upper X,
  sets exact-conversion Z and clears N/C/V. Signed zero, non-finite, subnormal,
  fractional, range and FZ/FIZ/AH cases are represented explicitly.
- FHM snapshots source/accumulator vectors before writes, widens binary16 to
  binary32 before multiplication and accumulation, selects the correct lower or
  upper source half, and clears unused destination bits. Numeric evidence is
  finite round-to-nearest only. Complete FPCR-directed rounding, exceptional
  values and hardware fused/exception fidelity remain unqualified.
- BF16 narrowing emits bit-level conversion with rounding-mode selection,
  ties-to-even for AH, DN/default NaN, FZ/FIZ, sticky exception inputs and scalar
  NEP preservation. BFCVTN clears upper bits; BFCVTN2 preserves the low half.
  Source aliases are snapshotted before destination writes. Streaming-mode
  special behavior is outside this repair's qualified scope.
- FCMLA retains the accumulator, passes an entire selected complex pair for
  indexed forms, identifies element width as 2/4/8 bytes, and clears unused upper
  bits. BFDOT/FCMLA arithmetic remains an opaque named SLEIGH operation; this
  tranche qualifies its inputs and outputs, not the helper's numerical result.

## Effect boundary

`ARM64FPProcessExceptions(exceptions:8, fpcr:8, oldFPSR:8) -> newFPSR:8` is an
explicit static-decompiler effect boundary. Conversion arithmetic is emitted
before the call. The test VM admits only normal-path sticky union and rejects
enabled exception traps. This is not a runtime FP trap implementation. Existing
native CALLOTHER handling must retain the unknown/effectful call; it must not
silently treat the call as a numerical oracle or claim hardware execution.

## Evidence and remaining acceptance

`tests/rx17_semantics.py` executes actual vendored `sleigh-lift` p-code with
byte-addressed, endian-aware storage. Each variant passed 384 FJCVTZS, 576 FHM
and 3,456 BF16 cases. RMIF passed 786,432 and CSSC 75,490 cases per variant.
The big-endian VM correction is retained with its original failed receipt and
focused corrected pass. The later FCMLA-only source change does not alter these
families; their receipts are reused rather than rerun.

`tests/rx17_dataflow.py` asserts opaque helper argument values, widths, rotation,
indices, aliases and destination clearing. Its sentinel callback is explicitly
a dataflow contract, not a numerical implementation. See the committed receipt
summary for exact counts and hashes. Static review was performed once over both
RX-17 and RX-18. Native provider scenarios, CoreTests, installed behavior and
Gate F remain build-root-owned pending acceptance.

The independent conversion oracle was informed by the pinned
[Sail Arm specification](https://github.com/rems-project/sail-arm/blob/1bf2e5574ba9d704639a28401b6a387dcb113cae/arm-v9.4-a/src/v8_base.sail)
(`FPToFixedJS`, `FPConvertBF`, `FPRoundBase`). No Sail implementation is vendored.

## RX-17b scalar FRINT32X/Z and FRINT64X/Z (2026-10-12)

All eight S/D scalar forms now round to an integral **floating-point** result.
X uses FPCR.RMode (nearest/ties-even, +infinity, -infinity, zero); Z uses zero.
The rounded value is range-checked against the selected signed 32/64-bit range.
NaN, infinity and rounded overflow produce the FP encoding of -2^31 or -2^63
and IOC, not saturation to the nearest endpoint and not raw integer sentinel
bits in an FP register. S sentinel encodings are `cf000000` / `df000000`;
D encodings are `c1e0000000000000` / `c3e0000000000000`.
Fractional valid results set IXC (including Z); invalid suppresses the new IXC.
Signed zeros, FZ/FIZ/AH input handling, source/destination aliases, FPSR sticky
bits, FPCR.NEP destination preservation and upper-Z clearing are explicit.

The oracle independently uses Python exact integer ratios. Architectural basis:
Arm's [A64 instruction specification](https://documentation-service.arm.com/static/67e40f3398aa3c3b6eea6a85)
and the pinned [Arm-derived Sail FPRoundIntN](https://github.com/rems-project/sail-arm/blob/1bf2e5574ba9d704639a28401b6a387dcb113cae/arm-v9.4-a/src/v8_base.sail)
(including FPUnpack and FPProcessException). No reference implementation is copied.

`RX17_FRINT_VALIDATION.json` records 2,272 actual emitted-p-code cases per
LE/BE/Apple variant (6,816 total). The focused Python feature selector owns
Apple; `rx17_semantics.py --suite frint --variant le --variant be` owns LE/BE.
SLEIGH compilation used the existing `compile_sleigh_aarch64_specs.sh` path:
one compiler, one of three shared heavy slots, zero wait, 1.11 seconds. Apple
execution took 1.08 seconds, LE/BE 2.62 seconds. Unchanged RX-17 families and
Swift decoder tests were not rerun: they prove no changed scalar SLEIGH behavior.
The existing script now retains failed compiler logs; the original reserved-word
syntax failure and focused correction remain recorded, not relabeled as passes.

The package identity update derives from the retained baseline per-file index
and existing overlay identities, replacing only changed members. No immutable
package/source re-verification, corpus pass, Swift build or native acceptance
was run. `tests/rx17_native_acceptance_vectors.json` remains
`prepared_not_native_executed`; trap-enabled hardware/native behavior remains
unverified. Vector FRINT32/64 constructors contain the same TRUNC/width defect,
but are intentionally unchanged under the scalar-only task boundary.

## RX-17c branch-free FJCVTZS, BF16 and scalar FRINT bodies (2026-10-13)

Lane AK (#467) found that the intra-instruction `goto` control flow in patches
0008, 0010 and 0013 made Ghidra split one instruction into 21-97 basic blocks,
which the native exporter's instruction-granular CFG rejects
(`native-provider-basic-block-count-invalid`). Those bodies are now branch-free:
every path is computed and the results are combined with masks
(`x * zext(cond)`, `(a & m) | (b & ~m)` with `m = 0 - zext(cond)`), so each
instruction lifts to one basic block with zero BRANCH/CBRANCH ops. The same
macros also make BFCVTN/BFCVTN2 branch-free. Semantics are intended to be
identical; the differences in encoding are:

- `ARM64FPProcessExceptions` is now called unconditionally (with exceptions 0
  on the no-exception path), and its result is selected into FPSR only when
  the exception mask is non-zero. FPSR is therefore bit-identical to the
  conditional call, but the effect appears on every path; a consumer that
  counts helper calls sees one per conversion instead of zero-or-one.
- Variable shift counts are masked to 0..63 (`& 63`) instead of being guarded
  by a branch; the out-of-range lanes are discarded by the select, so no
  result depends on p-code's oversized-shift rule.
- FRINT applies the sign of a zero result by OR-ing the source sign bit into
  `int2float(value)` instead of a conditional `f-`. This is exact because every
  negative input that does not round to zero already converts to a negative
  float, and the invalid result (`-2^(N-1)`) is negative for either sign.
- FPCR.NEP upper-bit preservation is `source * zext(NEP)` (BFCVT) and
  `Rd * zext(NEP)` (FRINT) instead of a conditional copy.

Verification once on the regenerated `.sla` (LE `99126195...`, BE `230b83f9...`,
Apple `1bc0f833...`): `rx17_semantics.py --suite fj|bf16|frint` passed FJCVTZS
384, BF16 3,456 and FRINT 2,272 cases per variant across LE/BE/Apple. The ten
RX17 words now lift to one basic block each and pass the exporter's CFG check,
but native admission still fails, now with `native-provider-output-budget-exceeded`:
the conservative encoded-size estimate for one FJCVTZS/BFCVT/FRINT function is
1.9-3.6 MB against the sealed `native-product-budget-v1` limit of 1 MiB
(121-242 p-code ops, 604-1,123 pseudocode tokens). That is a product budget and
estimator question, not a SLEIGH one; see the lane AM inbox note.

## RX-18 Wave 3 boundary

The bounded SME/SME2 overlay and its explicit scalable-state limitations are
documented in `RX18_SME_DECODE.md`; counts and the remaining WHILEGT gap are in
`RX18_VALIDATION.json`. This adds decode/effect coverage without upgrading any
RX17 or RX18 native acceptance status.
