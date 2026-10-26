# MachOKit vendored materialization

This directory contains the exact, already-qualified MachOKit 0.52.2
direct-source materialization. The payload is copied byte-for-byte from the
verified local cache
`machokit-0.52.2-e6796548485d32a183c3e1641989d637f5f6344c9e5af5a9cfbb83f549007950`.

The cache was accepted by `Scripts/machokit_source_identity.py` before
vendoring. `materialization/MATERIALIZATION.json` records the provider
revision, archive checksum, three transitive Git revisions/tree identities,
governed source identity, and complete materialization tree checksum.

The payload is direct source only: no symlinks, binary packages, XCFrameworks,
or network-backed package dependencies are admitted. Published files and
directories are read-only. The canonical offline verifier is invoked through
`verify_materialization.sh` from this component directory.

To reproduce or replace this payload, first obtain the exact reviewed
MachOKit archive and three clean detached transitive checkouts through an
explicit offline/local-cache preparation step. Run
`Scripts/dependencies/materialize_machokit.py materialize` with those inputs,
verify the result, and replace this directory only after the complete reviewed
tree checksum matches. Ordinary builds and verification must not acquire
source or resolve packages from the network.

Rollback is recoverable: remove this vendored directory in the dependency
commit and restore the prior external materialization/input seam.
