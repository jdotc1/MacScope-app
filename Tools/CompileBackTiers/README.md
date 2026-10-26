# Comparing rebuilt machine code

This standalone Python tool compares symbol-paired functions from two thin arm64
Mach-O files. It does not import or call the application. It uses the installed
Xcode `llvm-objdump` at the path declared in `tiers.py`; no packages are required.

```sh
/usr/bin/python3 -I Tools/CompileBackTiers/tiers.py \
  original.unstripped original.nm.txt rebuilt.unstripped rebuilt.nm.txt result.json \
  --callee-names --list-all --sections --units \
  --source-root A=/original/source --source-root B=/rebuilt/source

/usr/bin/python3 -I -m unittest discover -s Tools/CompileBackTiers/tests
```

An optional positional label follows the output path. Flags also work without a
label. Analysed comparisons exit zero, including comparisons with differences or
no paired functions. Invalid inputs and output failures exit two and emit a JSON
error; the error is also written to the requested output when that path is usable.
Successful runs write the full JSON receipt and print that same result.

The reference sanity comparison used sample application's unstripped and stripped files,
with the unstripped symbol listing supplied for both sides: 4,699 paired functions,
4,699 exact, zero normalised, and zero different (3.1 seconds in the retained
reference run). These are previously measured example numbers, not a claim that
this implementation has repeated that measurement.

## Pairing and tiers

The tool reads `__TEXT,__text` from `LC_SEGMENT_64` commands and accepts `T`/`t`
entries from `nm`, skipping `__mh_execute_header`. A function runs from its symbol
address to the next distinct symbol address, or the end of `__text`. Names present
on both sides form pairs; aliases with an identical address pair count once.
The receipt includes both unpaired-name counts and the first 50 names on each
side, distinct-address function counts, and the number of deduplicated aliases.

- **Exact:** the function's machine-code bytes are identical and every resolvable
  referenced constant (after source-root masking) has identical content.
- **Normalised:** bytes differ, but instruction streams match after the masks and
  constant-content annotations described below.
- **Different:** normalised instruction streams differ.

Size buckets use the first input's function size: at most 16, 64, or 256 bytes,
then more than 256 bytes. Without `--list-all`, the JSON retains twelve examples
per non-exact tier. With it, `non_exact` includes every non-exact pair, both sizes,
both addresses, tier, and the first raw and masked instruction differences. Each
difference is a zero-based index plus the two instruction texts; a missing
instruction is null. An equal stream has a null difference.

Identical bytes with a differing referenced constant are **different**, with
reason `constant`; the masked difference lists, per differing reference, the
instruction index, the section and both content hashes. A same-length edit of a
directly resolved string at the same address is therefore never exact.

## Reasons for a different function

Every different function carries one reason, counted in the receipt's
`different_reasons` and repeated on its `non_exact` entry (normalised entries have a
null reason):

- `constant`: identical bytes, but a referenced constant differs.
- `unverified-constant`: writeback invalidated a tracked page base; the function
  remains different and uncertified even when its code bytes are identical.
- `restored-page-base`: the strict scan differs, but a second scan in which loads
  based on `sp` (`ldr`, `ldp`, `ldpsw`, `ldnp`: callee-saved restores and spill
  reloads) do not drop page bases makes the two streams equal. At commit
  `093d9ab033026e16490a5db3302afeb32f956b75`, this reason labelled 0 of the 1
  same-meaning edit miss and 1 of the 5 cross-optimisation controls (The sample’s
  `___llvm_profile_initialize`) on the retained builds. The strict different tier
  stays unchanged.
- `incomplete-stream`: the disassembly of one side does not cover the function's
  bytes. The failure is recorded for that function and the comparison continues.
- `path-length`: both source roots are supplied, and every masked instruction
  difference changes only immediates in matching `mov`, `movz`, `movk`, `add`, or
  `sub` instructions by exactly the absolute difference in root lengths. Other
  operands and unchanged immediates must match. This labels a difference without
  changing its strict tier. The retained base/original comparisons contain this
  path-length leak in sample application 1 of 4,699 functions, control application 0 of 728, and math
  0 of 2,917. sample application's `FootprintWindow.applyGeometry` changes `mov w2, #0x6f`
  to `mov w2, #0x7a`: the difference of 11 equals the root-length difference.
  A certificate build uses the exact recorded source root, or a root of equal
  length when that path cannot be reproduced, to remove this leak by construction.
- `instruction`: any other difference in the masked instruction streams.

## Normalisation

The disassembler command is `llvm-objdump -d --section=__text
--no-show-raw-insn`; symbol annotations and comments are removed. Page values in
`adrp` are masked, while the destination remains a tracked page register until
redefined. `mov` propagates a page value; calls drop x0 through x18. A write to `wN` redefines `xN` and drops its page tracking, and `ldp`, `ldpsw`
and `ldnp` redefine both destination registers. (Earlier versions of the tool
kept only the first destination and the spelling of the register; both are fixed.)

A non-writeback memory offset or unshifted `add` immediate used with a tracked
page register becomes `#LO12`. Writeback addressing withholds constant digests
and DATA tokens, preserves its immediate, and invalidates its tracked page base;
only unshifted `add` treats a second-operand page register as a lo12 reference,
while every other second-operand immediate stays verbatim without a digest.
For unshifted `add`, `ldr`,
`ldrb`, `ldrh`, `ldrsw`, and `ldp`, the original page and immediate also locate a
referenced constant. Addresses in `__TEXT,__cstring`, `__const`, `__literal4`,
`__literal8`, `__literal16`, or `__oslogstring` append
`CONST:<first 16 hex characters of SHA-256>` to that mask. Strings include their
terminating NUL; other constants hash 16 file bytes beginning at the address,
including following file bytes when the window crosses the section boundary.
A truncated window or unterminated string is an input error. Any masked lo12 use
of a live page register into `__DATA` or `__DATA_CONST`, except `__got`, appends
`DATA:<segment>,<section>` instead. This token identifies a section, not object
content. Other addresses retain the plain mask. Loads without a lo12 immediate,
indirect references, `adr`, and PC-relative literal loads do not receive content digests.

The `DATA:` token is part of the compared text. A token present on one side only,
or two different tokens, therefore gives the different tier, even when the
surrounding instructions match. Example (sample control): four 12-byte
partial-apply and Objective-C thunks (`adrp`, `add`, `ret`) resolve to
`__DATA,__llvm_prf_cnts` on one side and to no data section on the other. Those
four moved from normalised to different, and the control's
exact/normalised/different counts went from 340/2039/4791 to 340/2035/4795. The
coarse section rule has a reach cost: it withholds otherwise-equal units outside
the selection (B comparisons: sample application 2111, control application 252, math 536). For A
comparisons, 1 of 4675 outside-selection units is uncertified in sample application, and
none in the other two.

For string constants beginning with the corresponding recorded source root, that
root is removed before hashing. Matching respects path-component boundaries and
allows a trailing slash in the root option. Path masking is opt-in and each side
has its own root.

PC-relative `adr` and literal `ldr` targets are masked. With `--callee-names`,
`bl` targets and external branches use `CALL:` and `TAIL:` plus the callee's name
(the lexicographically first alias), or `EXT` when unresolved. Without the flag,
external targets become `EXT`. In-function branch targets become offsets relative
to the instruction; for `tbz` and `tbnz`, only the last hexadecimal operand is the
target, so the bit number remains intact. An incomplete non-exact instruction
stream is an error rather than an equal comparison.

## Units and certification

`--units` forms each parent's unit from itself and its nested symbols. Swift
members have the entire parent mangled name as a proper prefix, including closure,
local-function, specialisation and thunk suffixes. Objective-C and C blocks match
`___<digits><parent>_block_invoke<suffix>` or `___<parent>_block_invoke<suffix>`;
the embedded parent name must match in full. The C name omits its leading Mach-O
underscore. Aliases still count once. A nested symbol present on only one side
makes its unit different with reason `unpaired-member`.

The receipt's `functions` array includes exact pairs as well as non-exact pairs,
with aliases and direct `data_sections` (also separated by input side). With
`--units`, each entry also has `members`, `unit_tier` (the worst member tier:
exact < normalised < different), and `unit_reason` (the differing members and
reasons, or null). `unit_data_sections` combines all members' references.

A referenced data section that is not byte-equal withholds certification. The
section dependencies are transitive: `__cfstring` also checks `__TEXT,__cstring`
and `__TEXT,__ustring`; `__objc_selrefs` checks `__TEXT,__objc_methname`;
`__objc_classrefs` and `__objc_superrefs` check `__DATA,__objc_data`. Other sections
have no additional dependency. A dependency absent from both files contributes
no changed bytes; one present on only one side is unequal. Direct missing section
records are treated as unverified. No object pointers are followed.

Each entry lists `data_unverified_sections` for its direct references and
`unit_data_unverified_sections` for all members. With `--units`, `data_unverified`
is true if any member has a changed direct or transitive section. `certified` is
true only when the unit tier is exact or normalised and `data_unverified` is false.
The certificate consumer must require this field. This tool reports eligibility;
it does not issue a certificate.

File totals include `data_referencing` (direct references), `data_unverified`,
`unit_data_referencing`, `unit_tiers`, and `certified`, all over deduplicated pairs.
Without `--units`, `certified` is null, and no function is marked certified.
Section equality is computed for this rule even without `--sections`; that flag
includes the detailed section records. The coarse data rule can withhold an
otherwise equal function because unrelated bytes changed in its data section.

## Known gaps

- One-level following of a `__cfstring` object remains unimplemented: its 32-byte
  object contains a buffer pointer requiring decoding through the image's
  chained-fixup format and a length field. The section rule covers changes
  conservatively until that object comparison exists.
- Swift static array storage also needs one-level object following and fixup
  decoding; it currently uses section equality.
- `__got` references are not resolved to bound symbol names. A changed import is
  invisible to the current normaliser.
- Stub calls under `--callee-names` without `--macho` disassembly render as
  `CALL:EXT`. This is an instrument limit; the semantic-edit measurements never
  change callees. The current command does not enable `--macho`.

## Section reporting and reference comparisons

`--sections` records SHA-256, stored and virtual sizes, and byte equality for each
section. It also reports file-backed segment ranges, including `__LINKEDIT`, whose
symbol-table changes cannot be located by section records alone. Zero-fill
sections have no stored bytes; their digest is the digest of the empty string,
with their virtual size reported separately. No whole-file digest is computed.

The importable `analyse(args, baseline_normalise=None)` interface optionally accepts
a reference normaliser with the signature `(sequence, start, end, names)`. It
compares both versions using the same disassembly and records `baseline_tiers`
and every `baseline_tier_changes` entry. Reasons identify constant-content
changes and flag any other normaliser difference for review. This avoids repeating a binary
measurement merely to recover the old tier of an individual function.

## Application and automation boundary

At base commit `88b3badb3927d254afad30fe64fabad7c817a591`, searching for `Tools/`
found only the existing native bridge references:

| File | Lines | Referenced directory |
| --- | --- | --- |
| `MacScope/project.yml` | 1917, 2023 | `Tools/NativeDecompilerBridge` |
| `.github/workflows/ci.yml` | 239, 244 | `Tools/NativeDecompilerBridge` |

The search was `rg -n 'Tools/' MacScope/project.yml .github/workflows`. This new
directory is outside the application targets and their automation configuration.
The tests use instruction text, fake section maps, and mocked input failures;
they do not open real executable inputs or invoke the disassembler.
