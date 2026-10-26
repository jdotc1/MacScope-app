# MachOKit dyld shared-cache metadata integration

## Scope and authority

MachOKit 0.52.2 is an exact-pinned direct-source dependency intended only for
`AnalysisWorkerXPCService`. It supplies supplemental cache-wide metadata. It
does not replace MacScope's cache loader, Mach-O parser, or `LoadedBinary`.
Those MacScope-owned paths remain authoritative for selected-image bytes,
offsets, address translation, identity, patches, and downstream analysis.

Pointer-bearing vendor models and mapped bytes remain inside the worker. XPC
replies contain only bounded MacScope-owned value records. The initial lane
adds no UI or workspace persistence and transfers no field authority.

## Reviewed identities

| Component | Commit | Git tree |
|---|---|---|
| MachOKit 0.52.2 | `773e10797abc53914b94c2ee8c6f40f5da0b06eb` | source archive tree `0a0bdc104b7f20c3f34ef595e113152cfc78ec496e96e14cb4957cf4d81dd038` |
| swift-fileio | `d589ff3966f9f064574780f527449a946736b989` | `71314646e1831c21a9480f566396c6a77b7b6d32` |
| swift-fileio-extra | `8d83506dd4dff737807d90dbf2264096ed98c7a7` | `95164a7178898951a246c4ce618de91989f8da7a` |
| swift-binary-parse-support | `5fb96b503672ea4752eded6b4e301fd87214b03b` | `5815e8dafb8899121841b11451502773a9a8fa96` |

The verified materialized-tree SHA-256 values for the three transitives are,
respectively, `07d7a1b2821566423aee3677c7f1fc066621dcd0dbe4c9b608c092040a304da4`,
`3556201836c8410c92f069c8212e1429b83d37b165f8db9aa6e7289dca7f9c5b`,
and `202d95c8aaca323d1f47db470e7a451a66f1d125711cd13c5a928da0f474eeb3`.

The MachOKit archive SHA-256 is
`2e6d429f248ac3f01b896379c3c77518858a2213ef3da0d89939d112de9fd945`.

The admitted governed-source identity is
`b2f928cfc635b3a539129d1dbd50464c9d218c4a815553bc4b710ac813a790ea`.
The schema-3 materialization tree identity is
`e6796548485d32a183c3e1641989d637f5f6344c9e5af5a9cfbb83f549007950`.
The content-addressed operator root produced during qualification was:

```text
$MACSCOPE_WORK_ROOT/macscope-deps/machokit-0.52.2-e6796548485d32a183c3e1641989d637f5f6344c9e5af5a9cfbb83f549007950
```

## Source-level license closure

The upstream package-level MIT file is not the complete license expression for
the compiled direct-source closure. SwiftPM compiles the complete `MachOKitC`
target, including its public headers. A source-header audit of that exact target
found the following additional records:

| License or notice | Compiled source files |
|---|---|
| APSL 2.0 Apple Original Code | `include/dyld_cache_format.h`, `include/fixup-chains.h`, `mach-o/fat.h`, `mach-o/loader.h`, `mach-o/nlist.h`, `mach-o/reloc.h`, `mach-o/stab.h`, `mach/machine.h`, `mach/vm_prot.h` |
| UCB BSD four-clause | `mach-o/nlist.h`, `mach-o/stab.h` |
| Christopher G. Demetriou BSD three-clause | `mach-o/reloc.h` |
| Carnegie Mellon Mach permission/disclaimer | `mach/machine.h`, `mach/vm_prot.h` |
| Apple OSReference header | `mach/machine.h`, `mach/vm_prot.h` |

Accordingly, the machine-readable expression is `MIT AND APSL-2.0 AND
BSD-4-Clause AND BSD-3-Clause AND LicenseRef-CMU-Mach`. The complete APSL text,
the exact source license blocks, and the exact OSReference notice are retained
under `ThirdParty/MachOKit/` and indexed by `THIRD_PARTY_COMPONENTS.yml`.
This correction does not approve public distribution; the existing private-only
distribution block remains in force pending a distribution-specific review.

## Explicit offline materialization

Normal build and test commands never acquire or mutate dependency source. An
operator first supplies the reviewed archive and three clean local checkouts:

```sh
python3 Scripts/dependencies/materialize_machokit.py materialize \
  --output-root /external/dependencies/machokit-0.52.2 \
  --machokit-archive /path/to/MachOKit-0.52.2.zip \
  --local-source /path/to/swift-fileio \
  --local-source /path/to/swift-fileio-extra \
  --local-source /path/to/swift-binary-parse-support
```

The tool checks the archive digest, extracted provider tree, every transitive
commit and Git tree, clean checkout state, ordinary-file shape, fixed budgets,
local-only SwiftPM manifests, and the absence of an XCFramework. After the
closed source is verified, it generates the public target source
`MacScopeMachOKitBuildIdentity.swift` containing exactly:

```text
MACSCOPE_MACHOKIT_BUILD_ID:773e10797abc53914b94c2ee8c6f40f5da0b06eb:b2f928cfc635b3a539129d1dbd50464c9d218c4a815553bc4b710ac813a790ea
```

The generated source is part of the `MachOKit` target. The independent verifier
recomputes the governed identity, requires an exact receipt and exact generated
source, and rejects missing or drifted markers. The materializer publishes only
after staged verification, freezes every file read-only and every directory
non-writable, and refuses to replace any existing result. The verifier accepts
that frozen shape while continuing to reject symbolic links, multiply linked
files, nonordinary nodes, writable publication paths, and content drift.

Normal consumers run the independent read-only verifier:

```sh
python3 Scripts/machokit_source_identity.py verify \
  --materialization-root /external/dependencies/machokit-0.52.2
```

The verified root may then be linked to the repository's ignored local-package
path with the verifier's explicit `link` command. Source acquisition is not a
bootstrap, XcodeGen, build-phase, test, signing, or application responsibility.
`MacScope/LocalPackages` is only an ignored, machine-local symlink to that
verified root; it is never tracked source authority. The two documented local
package-manifest adaptations are the only modifications to upstream source.
No supplemental result changes persistence, the selected-image or address
authority, MacScope's native parser, or downstream analysis semantics.

## Rollback and qualification ceiling

Remove the external root and ignored local-package link, then revert the
integration commit. Unit/provider tests do not waive the final signed-XPC,
Release, provenance, offline-build, or installed-product requirements.
