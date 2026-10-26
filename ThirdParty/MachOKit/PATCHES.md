# MachOKit materialization patch ledger

MacScope does not modify MachOKit implementation source. The explicit
`Scripts/dependencies/materialize_machokit.py` tool applies three deterministic
adaptations to the reviewed MachOKit 0.52.2 source:

1. `MachOKit/Package.swift` becomes a macOS-only, local-path package exposing
   only `MachOKit` and `MachOKitC`. Unrelated archive/readable products and the
   non-Apple conditional crypto closure are excluded.
2. `swift-fileio-extra/Package.swift` becomes a local-path manifest referring
   to the exact reviewed `swift-fileio` and `swift-binary-parse-support` trees.
3. `MachOKit/Sources/MachOKit/MacScopeMachOKitBuildIdentity.swift` is generated
   after the admitted source closure is complete. It exposes the public marker
   `MACSCOPE_MACHOKIT_BUILD_ID:<provider-revision>:<governed-source-identity>`
   from inside the compiled `MachOKit` target. The governed identity excludes
   only this generated file and `MATERIALIZATION.json`, avoiding a circular
   digest while binding the compiled marker to every admitted upstream,
   transitive, and local-manifest source byte.

No upstream Swift, C, or C-header implementation file is patched. The generated
Swift identity source is MacScope-owned and reproducible from the verified
closure. The materializer has no acquisition path: the exact MachOKit archive
and three clean, detached transitive checkouts must already exist locally. It
stages and verifies the complete closure before one atomic publish, freezes all
published files read-only and all directories non-writable, and never replaces
an existing accepted tree.

Rollback: remove the external materialization and the untracked
`MacScope/LocalPackages` symlink, then revert the MacScope integration commit.
