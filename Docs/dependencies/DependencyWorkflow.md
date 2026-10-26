# Reproducible dependency workflow

## Current operating rule

The private product build is self-contained. Canonical Git blob bytes for the
tracked `ThirdParty/` closure and its contracts are dependency source authority.
Ordinary `bootstrap.sh`, `test.sh`, Xcode, and canonical qualification may build
or reuse verified artifacts only in dedicated external work roots. They must
not clone, fetch, download, update submodules, resolve floating packages, or
invoke a CMake/Zig network fetch.

The current closure includes Ghostty VT/full surface, Zig and the reviewed
package stores, native SLEIGH/Ghidra sources/resources, MachOKit and transitives,
SwiftAssembly, and XcodeGen. `THIRD_PARTY_COMPONENTS.yml`, notices, licenses,
patch ledgers, materialization/source manifests, and `Scripts/*.contract` bind
their identities. Checkout normalization, ignored debris, or generated output
must never redefine the governed bytes.

The canonical candidate entry point is:

```zsh
./Scripts/qualify_local_private_build.sh \
  --work-root /absolute/external/macscope-qualification \
  --integration-ref refs/remotes/github/main \
  --mode prepare
```

Verify that the named remote resolves to canonical GitHub and its tracking ref
is current. Choose `smoke`, `focused-test`, `full-test`, or `release` instead of
`prepare` for the intended gate; see the root README for focused selectors.

Ordinary runs omit `--materialize-dependencies`; repository-owned inputs are
complete and the receipt must record that network use remained false.

## Producer/consumer contract

Every dependency lane must prove, in one static pass:

1. the immutable Git blob/tree/archive and patch identities;
2. the verifier and external artifact producer;
3. the exact generated manifest and ordinary-leaf/symlink/special-file rules;
4. every bootstrap, project, build-phase, runtime, signing, and provenance
   consumer;
5. that verified bytes are exactly the bytes compiled, linked, embedded, and
   signed; and
6. an explicit rollback to the prior verified pin or implementation.

Source and generated roots must be disjoint. Ghostty VT and full-surface
artifacts use separate roots. SLEIGH native libraries/resources remain in the
native XPC product closure. MachOKit remains worker-only supplemental evidence.
No dependency type becomes persisted or app-authoritative.

## Adding or updating a dependency

1. Define the intended integration and affected files.
2. Record approval of the component in the dependency inventory.
3. Record the exact revision/tree/archive hashes, source closure, transitives,
   licenses/notices, patches, expected outputs, and rollback.
4. Add an explicit refresh/acquisition script only when required. It must be
   manually invoked, immutable/checksum verified, absent from ordinary build
   call graphs, and unable to overwrite an existing destination.
5. Vendor or otherwise publish the reviewed source through canonical Git blobs;
   normal builds never depend on a mutable acquisition checkout.
6. Run the consolidated build-free gate once:

   ```zsh
   python3 -B Scripts/dependencies/validate_policy_consistency.py
   python3 -B Scripts/dependencies/validate_third_party_components.py
   python3 -B Scripts/dependencies/validate_offline_build_surface.py
   python3 -B -m unittest discover -s Scripts/tests -p 'test_dependency_governance.py'
   ```

7. Prove deterministic clean export/build, malformed-input/cancellation/resource
   limits, source-map fidelity, differentials, and the full product suite at the
   integration boundary.

A passing compile is not dependency acceptance. Native parsers/decompilers stay
behind the required signed worker boundary, and public distribution remains a
separate license/security/reproducibility decision.
