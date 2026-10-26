# swift-assembly direct-source dependency

MacScope admits one reviewed form of `swiftbin/swift-assembly`: selected direct
source. No Swift package, XCFramework, binary product, package-manager edge, or
other integration form is permitted alongside it.

## Frozen identity

- Repository: `https://github.com/swiftbin/swift-assembly.git`
- Commit: `b6798dbd0081ec989d25b5a0676ab8cbd36bd9b1`
- Git tree: `69fde307d20e1e8c73261cffffbf5a11f526a94c`
- License: MIT
- License SHA-256: `00511a028804276eb97fcc0cdba28ce973bcaf37cfa555d3cf934d9cec08f7cb`
- Integration form: 15 unmodified public Swift files under
  `Sources/Assembly/{ARM64,Core}`, flattened only by removing the upstream
  `Sources/Assembly` prefix
- Transitive packages: none; the selected sources import only Foundation

The immutable per-file sizes, Git blob SHA-1 values, and SHA-256 values are in
`ThirdParty/SwiftAssemblyVendor/SOURCE_IDENTITY.json`. The offline repository
anchor for that complete document lives in
`Scripts/swift_assembly_source_identity.py`. `MATERIALIZATION.json` binds the
identity, license, notice, and selected source bytes into one deterministic tree
receipt.

## Explicit materialization

Source acquisition is an operator action outside normal MacScope builds. Given
the already-present clean local checkout at the frozen identity:

```bash
python3 -B Scripts/dependencies/materialize_swift_assembly.py materialize \
  --source-root /absolute/path/to/swift-assembly \
  --destination /absolute/path/to/new/SwiftAssemblyVendor
```

The destination must not exist. The materializer verifies the clean Git commit
and tree, the exact 15-file closure, every source byte, and the MIT license
before publishing an atomically staged tree. It neither clones nor fetches and
does not invoke SwiftPM. It refuses an extra upstream source rather than
silently widening the reviewed compilation closure.

Verify the checked-in result through either implementation:

```bash
python3 -B Scripts/dependencies/materialize_swift_assembly.py verify \
  --materialization-root ThirdParty/SwiftAssemblyVendor
python3 -B Scripts/swift_assembly_source_identity.py \
  --materialization-root ThirdParty/SwiftAssemblyVendor
```

The second command is deliberately offline: it invokes neither Git nor a
network client and checks the source-identity file against an independently
hardcoded SHA-256 anchor.

## Source closure and authority

The vendored code is an internal assembler implementation detail. It must be
compiled exactly once in the intended target. Vendor types must not enter
MacScope persistence, XPC, or stable API contracts. MacScope remains authority
for address validation, architecture identity, independent decoding, and
fallback acceptance. The selected upstream source can only serve the separately
qualified long-tail assembler fallback; it cannot override primary MacScope
success or weaken substantive rejection. Malformed input, bad registers,
width/range/address failures, and every other substantive primary rejection
terminate without fallback. Absolute or symbolic PC-relative input is rejected
unless a real-PC upstream API is separately implemented and qualified. An
accepted fallback must preserve exact arm64 versus arm64e identity, return one
four-byte word, reproduce that word through the upstream round trip, satisfy the
closed alias policy, and independently decode to compatible semantics in
MacScope at the real address.

This reviewed pure-Swift target is an internal implementation of MacScope's
app-owned assembler boundary. It does not weaken the separate requirement that
native or otherwise crash-prone assembler engines remain service-isolated.

Normal bootstrap and build paths use the checked-in source tree and perform no
dependency acquisition. Any revision or closure change requires a new clean
source identity, license review, focused materialization mutation checks, and
the applicable assembler and target source-closure qualification.

## Rollback

Remove the direct-source target references in the owning `project.yml` change
and restore the prior fallback implementation. The dependency-admission commit
is intentionally separable from product routing, so the materialization can be
reverted without changing MacScope's primary assembler authority.
