# Portable production MacIR renderer

This harness runs the shipped MacScope load → decode → analysis → MacIR → CFG/RegionTree → pseudocode export pipeline on Linux. Complete product files are staged from an explicit source list with byte-identity provenance; only documented SDK/ABI overlays are generated.

See [USAGE.md](USAGE.md) for build, calibration and later-item measurement commands, [EXCLUDED.md](EXCLUDED.md) for dependency exclusions, and [DEPENDENCIES.json](DEPENDENCIES.json) for exact toolchain and official dependency versions.

Executed toolchain: Swift 6.4.1 (swift-6.4.1-RELEASE), x86_64-unknown-linux-gnu. Dependencies: official swift-crypto 3.12.3 and swift-asn1 1.3.1, plus the system zlib library. Dependency archives are not vendored or modified.

The harness directory contains source only. Generated source staging copies, module caches, dependencies and retained Debug build outputs are not delivery artifacts. No macOS app, Xcode test bundle, Release or GUI build is claimed.
