# Ghostty full-surface build inputs

- Upstream repository: `https://github.com/ghostty-org/ghostty`
- Upstream revision: `f64f4aca2c29b554d111b36c3d946a9bddd159ff`
- Upstream Git tree: `fa514474cca4b9bdceecb168d818b12b3bab0f1c`
- Upstream deterministic source digest: `a9702b7a9646f86e19d1938f16ca5701d57ff91476c3121d65a1a04431e773f5`
- Patched upstream Git tree: `b6aad1ba32602ee4eb3ea96fd88116a49ed09e97`
- Repository snapshot Git tree: `de6cd65b35a423d5d6854c6af3a90be20a52d7eb`
- Patched deterministic source digest: `ead5d48a8cda07addb59af1f35c6c9f7226bbdbd977b7330afd9714ecec6d8ab`
- Required Zig version: `0.16.0`
- Raw Zig package-store closed-tree digest: `70147cac57344d68a8dd812b7dd85b1d0eae984da531064e424128f937105d0f`
- Patched Zig package-store closed-tree digest: `13f8e6d6cc075fc5c13bb211e624c2a4311ff47cae414b44b7d509830adbf84c`
- Patched libxev package: `libxev-0.0.0-86vtcwIRFADbH4hk-EjROXxlrKIRPQdA41XiTSytYO-F` (upstream `9ce8e8e6ff89e583258a7f8e7adeeeaeae8611bf`)
- External-I/O ABI version: `1`

The raw and patched package stores exclude Finder `.DS_Store` and AppleDouble
`._*` metadata; package-store identity validation rejects either form.

The exact patched source snapshot is repository-owned at
`ThirdParty/GhosttySurface/Source`, and its closed Zig package store is
repository-owned at `ThirdParty/GhosttySurface/zig-pkg`. The retained
`Scripts/dependencies/materialize_ghostty_surface.sh` entrypoint documents and
reproduces how those snapshots were derived from upstream: it verifies every
patch before use, rejects a mismatched baseline, applies without three-way
fallback, and verifies the resulting Git tree and deterministic source digest.
It is not invoked by a normal build.

The dedicated `macscope-xcframework` Zig step depends only on the native
XCFramework graph. It does not execute Ghostty's default install graph, so
terminfo, shell integrations, completions, syntax files, translations, docs,
themes, web data, executables, and application bundles are not emitted.
It also sets `macscope-external-io-only=true`, disabling the root Zig
networking capability for this private artifact while leaving ordinary Ghostty
builds unchanged.

The exact official Zig toolchain is repository-owned at
`ThirdParty/Zig/zig-0.16.0`, with its canonical receipt at
`ThirdParty/Zig/zig-0.16.0.receipt.json`. The retained checksum-pinned
`Scripts/dependencies/materialize_zig_toolchain.sh` documents its provenance;
normal builds do not invoke it or acquire anything from the network.

`Scripts/dependencies/build_vendored_ghostty_surface.sh --work-root
<absolute-external-root>` verifies all three repository-owned inputs, snapshots
the Ghostty source and package store under
`<absolute-external-root>/GhosttySurface`, and builds the derived GhosttyKit
artifact there. Generated sources, caches, archives, manifests, and frameworks
never live under `ThirdParty`. The wrapper owns only its marker-bearing
`GhosttySurface` child and refuses to replace any unowned output.
