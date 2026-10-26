# MachOKit dyld shared-cache integration records

MacScope uses reviewed MachOKit 0.52.2 direct source only in the signed,
embedded `AnalysisWorkerXPCService`. The app communicates through bounded
MacScope-owned value records and does not persist MachOKit object graphs.

MachOKit supplies supplemental cache-wide catalog and metadata inspection.
The existing MacScope dyld shared-cache projector and `LoadedBinary` remain the
authority for selected-image bytes, identity, offsets, address translation,
patches, and downstream analysis.

Reviewed provider identity:

- repository: `p-x9/MachOKit`
- version: `0.52.2`
- revision: `773e10797abc53914b94c2ee8c6f40f5da0b06eb`
- archive SHA-256: `2e6d429f248ac3f01b896379c3c77518858a2213ef3da0d89939d112de9fd945`
- extracted source-tree SHA-256: `0a0bdc104b7f20c3f34ef595e113152cfc78ec496e96e14cb4957cf4d81dd038`

The three reviewed transitive commit and Git-tree identities are encoded in
both the materializer and the independent offline verifier. External source is
linked through the gitignored `MacScope/LocalPackages` symlink only after full
verification. No XCFramework or other binary form is accepted.

The dependency's top-level MIT license is not the whole compiled license
closure. `MachOKitC` contains nine APSL 2.0 Apple-origin headers, two UCB
four-clause BSD headers, one Christopher G. Demetriou three-clause BSD header,
two CMU Mach permission/disclaimer headers, and two Apple OSReference notices.
Their complete or exact upstream texts are retained beside this file and are
indexed by `THIRD_PARTY_COMPONENTS.yml`. `LICENSE.APSL-2.0.txt` is the SPDX
license-list copy of APSL 2.0 fetched from the read-only upstream license-list
repository on 2026-08-28; its SHA-256 is
`2d0c12edaaf8d31fec6796fef99291b12e833b6bef28100975120a53d209e06d`.
The BSD, CMU, and OSReference files are transcribed from the exact compiled
MachOKit 0.52.2 headers named in `docs/dependencies/MachOKit.md`.
