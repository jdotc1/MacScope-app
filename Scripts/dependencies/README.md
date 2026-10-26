# Dependency governance tools

Normal bootstrap/build/test paths verify repository-owned source/tool inputs
and build their artifacts offline. They do not acquire dependencies from the
network. `materialize_xcodegen.py verify-tool` verifies the tracked tool; its
name does not imply acquisition.

- `validate_policy_consistency.py` keeps repository contracts synchronized.
- `validate_third_party_components.py` validates pins, licenses, notices,
  patches, path coverage, and distribution gates.
- `validate_offline_build_surface.py` proves the ordinary build-script call
  graph contains no known network-acquisition operation.
- `audit_dependency_census.py` cross-checks the bounded census in
  `docs/dependencies/DEPENDENCY_CENSUS.md` against normal build/test/runtime
  source surfaces and the third-party inventory. It deliberately keeps Xcode,
  the macOS SDK, XcodeGen, and MTPLX classified as platform/tool/service
  inputs rather than source dependencies.
- `materialize_ghostty_vt.sh` is the explicit Ghostty source/build-input command.
  Its caller must provide `MACSCOPE_GHOSTTY_ZIG_PACKAGE_STORE_SOURCE` for a
  cache-miss materialization; that verified seed is checked before destination
  creation or network acquisition.
- `materialize_zig_toolchain.sh` independently materializes and verifies the pinned Zig toolchain used by that build.
- `materialize_pypcode_dcp03.sh` explicitly materializes the pinned non-shipping pypcode/SLEIGH DCP-03 proof environment and runs its native AArch64 self-test.
- `materialize_libghidra_dcp03b3.sh` explicitly materializes the pinned non-shipping libghidra 0.0.2 local-backend pilot and validates its native service/capability identity.

Network acquisition is restricted to explicitly invoked acquisition commands.
Offline verification and materialization of repository-owned inputs are part
of ordinary bootstrap; see the [root build guide](../../README.md#build-and-test).

## Ordinary offline producers

Bootstrap verifies the tracked XcodeGen tool, invokes
`build_vendored_sleigh_native_source.sh` for native SLEIGH, prepares the Ghostty
full-surface artifact, and publishes the MachOKit source materialization. The
Ghostty VT fallback builds from tracked source in its Xcode phase. All outputs
belong in external work roots; the source pins and validators remain binding.
The acquisition tools listed above are explicit maintenance/proof operations,
not fresh-checkout prerequisites.

## Internalized AArch64 processor resources

`internalize_sleigh_aarch64_resources.py` is an offline, repository-owned
materializer for the exact 25-file AArch64 closure accepted for the native
MacScope product path. It copies the pinned resources from
`ThirdParty/SleighNative/AARCH64` into an explicitly supplied external Derived
Data/work root and emits a digest-bound `MATERIALIZATION.json`. It performs no
network access, does not invoke Xcode, and never writes generated output into
the repository.

All tools use only the Python or shell standard environment supplied by macOS.

## DCP-03B3 native libghidra pilot

`materialize_libghidra_dcp03b3.sh` is an explicit, developer-invoked
materializer for the non-shipping native decompiler pilot. It selects only the
approved libghidra 0.0.2 host wheel, verifies the immutable SHA-256 before
extraction, installs no package through `pip`, and writes an ignored
`libghidra-dcp03b3/` environment. Normal bootstrap, build, test, XcodeGen, and
application paths must not invoke it directly or indirectly.

The pilot consumes DCP-03B2 effective bytes and preserves raw-byte,
relocation/fixup, symbol, and image provenance. It remains a shadow backend and
is not an application dependency.

## Historical DCP-03B4 native SLEIGH package qualification

`materialize_sleigh_native_dcp03b4.sh` explicitly downloads only the approved
lifting-bits/sleigh v12.1.2 host archive, verifies its immutable SHA-256, safely
extracts ordinary files, verifies the installed `sleigh::decomp` and
`sleigh::sla` CMake surface, required Ghidra headers, native libraries, and
AArch64 processor resources, and writes a deterministic `MATERIALIZATION.json`.

The ignored `sleigh-native-dcp03b4/` directory is not an ordinary build input.
The optional `MACSCOPE_ENABLE_SLEIGH_DECOMP_API_PROBE` CMake gate must be enabled
explicitly and must point at a verified ordinary-directory materialization root. CMake reruns the complete verifier before evaluating any upstream package configuration, so a linked root or tampered `sleighConfig.cmake` fails without execution. It then compiles,
links, and initializes the native API without enabling a MacScope application
backend.

## Historical DCP-04 signed XPC shadow integration

At the DCP-04 checkpoint, the service could consume an already verified SLEIGH materialization only through the
dedicated `NativeDecompilerXPCService` staging and build scripts. The staged
bundle-local package is reverified before signing and again by the service; the
main app target does not link or load its native archives. Activation at that checkpoint was developer-only, disabled by default,
shadow-only, and non-authoritative. DCP-05 supersedes those activation limits: the
private product now uses default-on native pseudocode. The app still does not
link native archives, and native results cannot mutate persisted workspace authority.

Ordinary bootstrap, build, and test entry points never download the package.
When an explicit materialization root is supplied to `Scripts/test.sh`, it is
forwarded as an Xcode command-line build setting so all targets consume the same
governed root.

The current GitHub source line builds the native package from its governed
repository-owned source closure during offline bootstrap. The historical
network-backed DCP-03B4 materializer is not a required fresh-checkout step.
