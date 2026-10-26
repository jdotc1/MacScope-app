# Native source patch ledger

The repository-owned `sleigh/` and `ghidra/` snapshots are unmodified selected
ordinary files from their exact upstream commits. MacScope applies no patch to
either tracked snapshot.

The upstream `lifting-bits/sleigh` stable build requires its eight checked-in
Ghidra patches. Those exact patch files remain under
`sleigh/src/patches/stable/` and are checksum-pinned by
`MATERIALIZATION.json`. The offline build wrapper copies the raw Ghidra closure
to the caller's external work root, creates local Git metadata there, and
applies the ordered patch series with `git am`. No three-way fallback, network
operation, or in-repository mutation is permitted.

The patch series fixes undefined behavior, 64-bit address parsing, floating
point qualification portability, strict weak ordering, and signed-shift
behavior. Two patches touch upstream unit/data fixtures, which is why the exact
`testfloatemu.cc` and `floatprint.xml` members are retained even though tests
are not built by the production wrapper.

To reproduce and qualify the source-built package:

```sh
./Scripts/dependencies/build_vendored_sleigh_native_source.sh \
  --work-root /absolute/external/work-root
```

The wrapper verifies the raw source identities before copying, applies only the
frozen upstream patch series, configures with acquisition disabled, and writes
the source-built package and receipt below
`<work-root>/SleighNativeSource/`. Rollback is described in `PROVENANCE.md`.
