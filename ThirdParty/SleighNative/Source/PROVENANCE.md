# Native SLEIGH/Ghidra source provenance

This directory is the repository-owned source closure for the governed native
package used only by `NativeDecompilerXPCService`. It contains ordinary files
from two official public repositories at exact immutable identities:

- `lifting-bits/sleigh`
  - repository: `https://github.com/lifting-bits/sleigh`
  - commit: `bfd38a983b4aa53dd386365e1df5ed5499b7e2fb`
  - Git tree: `20043e94b5933466b0861ad68f07f591f70c0050`
  - selected closure: upstream top-level CMake project, required `cmake/` and
    `src/` build/patch files, README, and Apache-2.0 license
  - selected closure SHA-256:
    `2af879c8587ba6b0913ee53b220f1580c92dd521de7671dc3ece8a750b47e622`
- `NationalSecurityAgency/ghidra`
  - repository: `https://github.com/NationalSecurityAgency/ghidra`
  - commit: `c0f584bf229fffba61b36431f3ce30c0c3e4e682`
  - Git tree: `2dfe30eddeefcd3efc9e49ea58bd725de5bbc4bb`
  - selected closure: native decompiler C++ sources plus the two test/data
    members required by the upstream stable patch series, module README,
    Apache-2.0 license, NOTICE, and government disclaimer
  - selected closure SHA-256:
    `fdcb64b623e3c881a95f16a29750e83fd124cc08149c347d3e56f58352cbe321`

`MATERIALIZATION.json` freezes the file counts, byte counts, tree identities,
upstream Git trees, and every accepted patch digest. The independent verifier
uses a length-framed, path-qualified digest and rejects links, non-regular
members, malformed/duplicate manifest keys, missing required source, and
identity drift.

## License boundary

Both selected upstream projects use Apache License 2.0 for this closure. The
complete license texts, Ghidra NOTICE, and Ghidra disclaimer remain inside the
snapshot. Required Bison-generated parser outputs retain their upstream Bison
special exception, which permits a larger work containing the parser skeleton
to use terms of its choice.

The optional GNU BFD bridge and console/development sources are not part of the
closure. The excluded paths are frozen in `MATERIALIZATION.json`; in
particular, neither BFD-backed load-image implementation nor a BFD-linked
console program can enter the source build.

## Build boundary

`Scripts/dependencies/build_vendored_sleigh_native_source.sh` verifies both raw
snapshots, copies them to an explicit absolute work root outside the repository,
applies the exact upstream lifting-bits stable patch series there, and invokes
the vendored upstream CMake project with FetchContent fully disconnected and
the local Ghidra source override fixed. It builds only the static `sla` and
`decomp` libraries, installs the public source-derived package seam, and adds
the separately governed repository-owned AArch64 resources. No ordinary build
or verification step downloads, fetches, or resolves source.

Generated source copies, Git metadata used to apply patches, object files,
archives, installed headers/configuration, resources, and receipts all remain
below the caller's external work root.

The source closure was qualified on 2026-08-30 with CMake 4.4.3, Ninja 1.13.2,
and AppleClang 21.0.0.21000333. A clean disconnected arm64 build applied all
eight frozen patches, completed 120 compile/link steps, and produced a
145-file package whose length-framed tree SHA-256 was
`ebb1e5d29c5ee4727b1f3c84cfb3618ec91eb10abdfcdd9b5d12f7dbcaf6299f`.
The built `libdecomp.a` SHA-256 was
`2810b53ff51332e79fbe633071b9a0380612e2c9f128fdc32d230b4318f432b5`;
the built `libsla.a` SHA-256 was
`05275c52a0164fd30caad7c0a74ef2f92fe074aed34f6f67bd15bac7741bb42c`.
Archive architecture and all governed header/resource seam bytes qualified.
These output hashes record this local toolchain proof; the immutable input
identities in `MATERIALIZATION.json` remain the reproducibility authority.

## Rollback

Revert the isolated native-source closure commit and continue using the already
governed prebuilt package at `ThirdParty/SleighNative/package`. The app/XPC
authority, runtime policy, and public-distribution block do not change.
