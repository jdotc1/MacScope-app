# C1: visible callee memory effects

C1 restores image-wide signature-typed indirect-slot proofs when every potentially
relevant write is in the analyzed inventory. The function-local proof is unchanged.

## Authority

A direct call is visible only when its source bytes decode as AArch64 BL imm26,
its checked signed PC-relative target belongs to `functionStarts`, and that target
has an analyzed function body. Names, rendered target text, and symbolized sidecars
never establish identity. A greatest fixpoint removes callers of opaque bodies;
closed recursive components remain visible only when every non-call transfer is
accounted for inside that function's own instruction addresses. Conditional targets
and fallthroughs, direct/tail branches, and every recovered-switch case and default
must stay inside that body. Missing, unparseable, external or indirect destinations
remove the function from visibility before the call fixpoint; CFG edge lists alone
are insufficient because unresolved edges can be omitted. Unsupported writes still poison the
image. Visibility does not excuse a callee's own parameter-rooted writes, foreign
roots, overlapping writes, multiple roots, or nonconstant stored values.

The queried indirect call alone is excluded because its effects follow its load.
Every other unresolved indirect, external, or non-analyzed call remains opaque.
There are no import contracts, global caches, GUI warm-ups, or new authority inputs.

## Frame writes and the run-2 / run-3 rulings

Track entry SP through immediate `stack_alloc` / `stack_free` and literal-SP
writeback. Unknown amounts, arithmetic overflow, unknown SP writes, or restoration
from another register permanently discard the delta. For conservative control-flow
handling, tracking is restricted to the entry basic block with no incoming edges;
no join or loop inference is attempted.

A frame write requires a complete typed memory sidecar that passes the existing
`rendersExactly` gate, a literal SP base (never fp/x29 or a copied pointer), a known
delta, and a known positive width. Ordinary stores additionally require a stackSlot
matching the raw SP-relative displacement; the tracked delta supplies entry-SP coordinates. Pre-index uses the updated address, post-index
the old address; the complete half-open extent must have start < 0 and end <= 0.
Pair stores count twice the element byte width. Scalar storeWriteback follows the
same rule. `restore_pair_writeback` writes no memory and updates only SP authority.

Frame locality alone does not establish separation: a live stack object can be
passed to a dispatcher. Before granting any frame exemption, scan the entire
function for escape, including instructions after the store and in other blocks.
Any SP-derived read as a value defeats every frame-write exemption in that function.
Only memory-base use, the four modeled SP intrinsics and immediate SP self-adjust,
and `mov x29, sp` / `add x29, sp, #imm` setup are permitted. Setup makes x29 derived;
subsequent x29 value reads escape except a proven in-frame x29/x30 frame-record
save. Memory-base use does not itself escape, but x29 still cannot establish frame
write authority. Unknown/unmodeled IR conservatively defeats the proof.

The first non-exempt value read is itself escape. The allowed alias producers are
frame-pointer setup and reloads of its saved frame record. All x29 versions are
conservatively treated as derived if any setup exists, avoiding optimistic joins
or kills. Saved frame-address locations are retained even after overwrites; loads
that may overlap them taint their destination register identities across versions.
Unknown load coordinates may overlap any saved record. Pair restores check each
element separately, so an ordinary `ldp x29, x30` restores derived x29 without
incorrectly treating the x30 destination as a frame-address read. A reloaded frame
address used as a return control target also escapes. Only plain `ret`/`ret x30`
and operand-free `retaa`/`retab` receive the ABI-return contract; noncanonical,
exception or unparseable returns are opaque. Authenticated returns still implicitly
read SP for authentication, so they defeat the separate frame-nonescape proof.

The four newly recognized intrinsics are `stack_alloc`, `stack_free`,
`save_pair_writeback`, and `restore_pair_writeback`. The existing destination-bearing
`adrp` case and its constant propagation are unchanged. Every other intrinsic keeps
main's behavior. The image-wide exemption has a separate local-unsupported flag:
all previous local barriers, path invalidation, and reaching-proof refusals remain.

## Evidence ownership

The run-1 failing-first receipt is retained in the external C1 handback: nine cases,
five passed and four failed; cases 1-3 failed as poisoned, case 9 used a caller-saved
object and was corrected to x19 in e04d8f56e. It is not rerun. Run 3 supplies real BL
bytes and decoder memory sidecars to the new fixtures without changing any original
expectation in IndirectTargetResolutionTests.swift.

One run of IndirectTargetWriteSeparationTests and IndirectTargetResolutionTests is
the authorized after check. No whole-image witness/export or corpus pass is part
of this slice. The lead owns review and merge; no merge or installed acceptance is
claimed by this lane.

## Run 4 blocker regressions

Tests were committed first as `6176fd1ea` (`[skip ci]`). The retained dev loop ran
eight changed/new selectors once against the unfixed resolver: five failures,
three passes, zero skips. The failing cases cover SP-derived argument formation,
x29-derived argument formation, stored frame addresses, external/unparseable
conditional exits and recovered-switch exits. The exact lead A1 call chain also
checks refusal; an escape-only companion removes the opaque dispatcher call so it
cannot mask the frame defect. The frame-pointer prologue/epilogue, typed incoming
argument write and internal conditional controls passed before the fix.

Case 6 now uses a decoder-produced complete memory sidecar for `str x9,[sp,#16]`,
so its refusal isolates the entry-SP boundary. Case 1 includes `mov x29,sp` and
`ldp x29,x30`; expectations are unchanged. The run-4 after check is one run of the
two named classes on the corrected resolver, using the same retained DerivedData,
four Xcode jobs and one heavy-job slot. No original expectation is relaxed.

The two named classes passed once at `0a28ac05b`: 46 tests, zero failures/skips.
A subsequent narrow correction accounts for implicit SP reads in authenticated
returns; only its new focused regression is selected, with the 46 passing cases
reused rather than repeating either class.
