# RX-18 Wave 3: bounded SME/SME2 decode

This overlay adds SME/SME2 constructors for RDSVL, ZERO, ZA and ZT0 LDR/STR,
FMOPA/FMOPS, LUTI2, MOVA, ZA LD1/ST1 and ADDHA/ADDVA. It also corrects
SMSTART/SMSTOP operand rendering and makes SMSTOP build its SVCR operand effect.
The allocated variants exercised by the bounded fixtures are explicit in
`tests/rx18_feature_vectors.json`. This is partial decode delivery, not full SME
execution or native-provider acceptance.

The encoding basis is Arm's A64 XML instruction tables, available in the
[Arm A64 specification](https://documentation-service.arm.com/static/67e40f3398aa3c3b6eea6a85)
and the [Arm-authored instruction pages](https://www.scs.stanford.edu/~zyedidia/arm64/).
Each newly assembled fixture names its XML instruction. Apple LLVM independently
assembled and printed 93 fixed assembly cases using generic AArch64 ELF with
SME2, SME_F64F64, SME_I16I64 and SME_F16F16 enabled. The other 39 rows are the
fixed checked-in RX18 decoder words. No binary-derived list, corpus, prevalence
scan, random sweep or hardware execution was used.

## State and semantic boundary

SME state is represented by `sme_svl_bytes`, a symbolic streaming vector
length in bytes, and `sme_za_state`, an opaque state token. The token is not a
physical ZA tile and its 64-bit storage does not assert a 64-bit tile width.
The new `zt0` register is exactly 512 bits. Existing upstream Z registers are
fixed at 256 bits, so full scalable ZA/Z/P arithmetic is not representable by
this overlay alone.

RDSVL multiplies symbolic SVL by the signed six-bit immediate. ZT0 loads/stores
use normal 64-byte p-code memory operations. SMSTART/SMSTOP update the selected
SVCR bits; their remaining effects stay opaque. ZA arithmetic, loads, stores,
zeroing, MOVA and LUTI2 retain explicit `SME_*_EffectsUnmodelled` calls with
state dependencies and outputs. LUTI2 writes its Z destination and reads ZT0;
it does not fabricate a ZA write. Tile-to-vector MOVA likewise writes Z.
Opaque memory-effect calls and FP-status calls are not numerical semantics.
The existing streaming-SVE forms still use upstream SVE userops.

## Focused evidence

`RX18_VALIDATION.json` records the following result **for each** LE, BE and
Apple variant:

| Scope | normal_path | decode_only | still_fail_closed |
| --- | ---: | ---: | ---: |
| 120 unique allocated words plus 12 reserved guards | 7 | 112 | 13 |
| Original 39 RX18 words | 3 | 35 | 1 |

The 13 fail-closed cases consist of 12 intended reserved guards and one
uncovered allocated streaming-SVE instruction: `25231057`,
`whilegt p7.b, x2, x3`. That gap remains within the assigned streaming-SVE
scope and is explicitly expected in the fixture. No claim of complete RX18
coverage is made. `normal_path` means emitted p-code has no CALLOTHER; it does
not mean native or hardware acceptance.

The **aggregate across all three variants** is 66 numerical cases (22 per
variant) for RDSVL and ZT0, plus 144 SVCR bit assertions (48 per variant).
RDSVL uses SVL values 16, 32, 64 and 256; ZT0 checks 64-byte transfers and
SP addressing. SVCR checks all SM/ZA selections with upper bits preserved.
ZA/Z/P effects are checked for explicit state dependencies and correct
clobber direction, not executed as tile arithmetic.

All three specs compiled through `compile_sleigh_aarch64_specs.sh` in 3.09 s,
using one compiler and one of three shared heavy-job slots with zero wait.
The first focused run used four workers and took 27.642 s. Its four failing
words were retried in 0.833 s after correcting the MOV/FMOV-zero alias and
Q MOVA assertion and explicitly recording the WHILEGT gap. Passing rows were
reused. The 144 SVCR assertions used the already captured p-code, avoiding
repeated disassembly/lifting. Failed compile attempts and initial assertions
remain in `t6-sme-20261012.noindex`.

The focused selector is
`Scripts.tests.test_sleigh_aarch64_feature_vectors.SleighSMEBoundedDecodeTests`.
The checked-in adapter was not rerun after recording the equivalent underlying
harness evidence. Existing FRINT/RX17 cases were not repeated. Native acceptance
is `prepared_not_native_executed`; no Swift/native build or GUI action was run.

Package identity was updated from the retained T2 per-file index, prior patch
identities and this compile receipt, replacing only changed members. Unchanged
package/source data was not rehashed or reverified. The old broad
`test_sleigh_aarch64_patch_contract.py` remains stale at patches 0001–0003 and
old closure identities; its baseline replay, recompilation and package rehash
were not run, both because the inputs already have receipts and because this
bounded tranche does not authorize a duplicate broad validation pass.
