# MacScope AArch64 SLEIGH patch ledger

The upstream release archive remains unchanged in `package/`; its accepted
identity remains in `MATERIALIZATION.json`. MacScope's modified resources live
in `AARCH64/`, with separate source, patch, compiled-output and overlay identities
in `PATCHED_RESOURCES.json`. Do not relabel the archive identity as patched.

| Patch | Change |
|---|---|
| 0001 | WP0 MOPS WT option, SET mnemonic and specification inclusion |
| 0002 | WP0 odd HINT exclusion from BTI and MOPS decoding |
| 0003 | WP0 rejection of aliased/invalid MOPS encodings |
| 0004 | Indexed dot operand export crash repair and accumulator input |
| 0005 | RMIF rotate and preserve unmasked flags |
| 0006 | CSSC upper-X clearing |
| 0007 | FHM and BFMLAL indexed lane operands |
| 0008 | FJCVTZS modulo conversion, NZCV and explicit exception effect (branch-free since RX-17c) |
| 0009 | FHM widening and accumulator/alias preservation |
| 0010 | BF16 narrowing, rounding and preserved halves (branch-free since RX-17c) |
| 0011 | Dot and FCMLA accumulator, complex-pair and element-size dataflow |
| 0012 | Explicit modification notice in the base specification |
| 0013 | Scalar FRINT32/64 rounding, range and NEP (branch-free since RX-17c) |
| 0014 | Bounded SME/SME2 decode identities, SVCR/RDSVL scaffold (RX18) |
| 0015 | CP1 bounded normal-path semantics for 105 forms; eight PMOV class identities and two FP8 identities remain explicit decode-only |

`RX17_SEMANTICS.md` defines qualified behavior and limitations. Modifications are
identified in each changed upstream source. Patches apply in numeric order to
the immutable archive's language sources with zero fuzz. The pinned compiler
builds AARCH64, AARCH64BE and Apple Silicon variants offline. The exact source
replay can reuse a matching compile receipt instead of recompiling unchanged
inputs. The archive baseline, compiler and identities are never downloaded or
silently replaced by this operation.

The producer publishes `package/`, `MATERIALIZATION.json` and
`PATCHED_RESOURCES.json` together. Downstream consumers must explicitly admit
and verify this two-identity contract. The frozen package's strict consumer still
requires the original two-member root and needs the build-root integration fix.

Rollback is a scoped revert of RX-17's source/resources/record and overlay
producer commits. Keep the immutable package and the existing accepted installed
application; this tranche performs no installation or replacement.

## CP1 offline checkpoint — not native acceptance

Patch 0015 preserves the vendored C++ closure and bridge. Scalable state extends
legacy Z/P storage without moving its low aliases; PN shares P, ZA has 256 rows
of 256 bytes, and ZT0/SVCR/configuration inputs are explicit. Generated p-code is
branch-free with varnodes bounded to unsigned 64-bit storage ranges.

The unchanged schema-4 corpus has 125 allocated forms and 853 cases. The CP1
normal-path evaluator reports **492 PASS / 0 FAIL / 102 UNSUPPORTED / 259 GATE**
for each of AARCH64, AARCH64BE and Apple Silicon. This is 105 implemented forms,
not full architectural conformance. Ten predicated ZA-memory forms and ten
floating-point outer-product forms remain unsupported. The 50 additional
predicate classes have decode-only recognition, not semantic passes. PMOV's
eight class renderers identify the class but do not yet print complete operands.

The CP1 resource closure has 29 files. On 2026-10-13 the Mac re-derived the pins with the
governed `package/bin/sleigh` (`tests/cp1/tooling/rederive_pins.py --recompile-with package/bin/sleigh
--write`): unmodified upstream recompiled byte for byte, package identity matched the immutable
archive, and the three owned SLAs were recompiled on the Mac (they differ in bytes from the Linux
checkpoint SLAs). `PATCHED_RESOURCES.json` now records `MAC_PINS_DERIVED_NATIVE_ACCEPTANCE_STILL_REQUIRED`
with the full package-overlay digest; the previous accepted Mac identities are kept separately.
The checkpoint ledgers use a test-only metadata/batch frontend built against the governed
`libsla.a` by `Scripts/dependencies/build_cp1_sleigh_lift.sh` (export its path as `CP1_SLEIGH_LIFT`).

`tests/cp1/README.md` documents the actual p-code VM and fixture run. The old
RX18-only effects-count contract is superseded by the CP1 checkpoint contract;
RX18 source and its baseline receipt remain unchanged. RX17 reruns passed all
4,416 cases per language, and the explicit frontend adapter passed 2,272 FRINT
cases. A raw-text size check is not the native 1 MiB budget check. Run the
canonical patch and feature tests, then the native evidence-word acceptance
lane once on the Mac. The supplied attachment omits that lane's full package,
compiler wrapper and legacy golden corpus; no Mac build, XPC acceptance or
installed-app claim is made here.

## CP1b second pass — 2026-10-13

Additive inner0017 fixes vertical MOVA subpieces,0018 prints decimal register selectors, and0019 packs conditional B/H/S MOVA destinations. There is no inner0016. The three source patches preserve C++/bridge source, architectural register/address-space definitions, the 256-byte unique limit and one-basic-block semantics. B/H/S snapshot both Z pieces before register stores; inactive lanes store the original source value to its original Z cell. This does not suppress RAM accesses or establish performance or native SSA behavior. D/Q retain the first-pass form.

The second-pass Mac compile used the already accepted governed compiler and three workers,38.057s total. The unchanged upstream compile/compiler/package member receipts were reused. Only new source/patch/SLA bytes received first identities; new resource tree c7e6f7fc0c4d5228f1073d4e3f0a3b510ab80252784e95869f8c5c26d015aa8d and archive-package overlay f58ca156d1fbe25f0941c37295b01e3b012be9937259aebb4e19db337f9b3eb6. The resource-only developer cache can be derived from its metadata-bound accepted parent via Scripts/qualification/derive_sleigh_resource_cache.py; native bridge identity consumers still require rebuilding against the new manifest. This is not Release qualification.

Native acceptance is closed with split receipts: 29 earlier passing words reused and the four formerly refused B/H/S/D words passed on the corrected native worker at the unchanged 1 MiB output budget; no passing word was rerun. See docs/build/CP1B_NATIVE_ACCEPTANCE_20261013.md for exact evidence and presentation bounds. Supplied Linux raw counts/equivalence/displays remain cloud evidence, not Mac acceptance. Optional20forms and259gatedcases remain out of scope. Mac evidence: codex-cp1b-evidence/compile-results.json and resource-identity.json.
