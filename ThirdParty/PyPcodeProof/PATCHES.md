# pypcode DCP-03 proof patch ledger

Component: `angr/pypcode` 4.0.0, upstream Git revision
`2787546a83b42a62dde3a1905deea8b0906e85b5`.

## Local patches

No upstream source or wheel patches are applied.

MacScope's request validation, canonical DTOs, CFG derivation, exact-storage
SSA, operand heritage, MemorySSA, AArch64 GPR alias SSA, base Darwin
call-input/clobber records, bounded effective-memory/relocation semantics,
supervisor, and tests are independent adapter/analysis code under
`Tools/DecompilerCoreProof/` and `Scripts/decompiler-proof/`; they do not modify
the materialized wheel or its bundled processor specifications.

## Reproduction

Run `Scripts/dependencies/materialize_pypcode_dcp03.sh`. The script downloads
one platform-specific CPython 3.13 wheel, verifies the exact SHA-256 declared in
the script and `THIRD_PARTY_COMPONENTS.yml`, installs it with `--no-index` and
`--no-deps`, and performs a native AArch64 language self-test.

The DCP-03B1 register semantics and DCP-03B2 effective-memory/relocation
semantics are dependency-free and can be tested without materializing the
wheel. Native fixture tests run only through the exact pinned interpreter.

## Rollback

Delete the ignored `pypcode-dcp03/` materialization and remove the
`pypcode-dcp03-proof` manifest/notice/allowlist records. No app target, Xcode
project, persisted document, or default decompiler path depends on this pilot.
The DCP-03B2 result contract can be rolled back independently by reverting
its schema, `load_image.py`, engine/verifier additions, and fixture/test/docs
updates. Doing so returns to the DCP-03B1 raw-byte lifting contract; no product
or persistence migration is required.
