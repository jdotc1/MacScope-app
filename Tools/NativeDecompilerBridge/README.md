# MacScope native-decompiler bridge

This directory contains the MacScope-owned C++ input/output seam and the accepted
opt-in direct native structured provider. It is deliberately independent of Mach-O
parsing, Swift application state, rendered pseudocode text, and upstream Ghidra
object lifetimes.

DCP-03B4 provides a dependency-free C++20 contract containing:

- caller-owned raw-byte provenance plus the independently derived DCP-03B2
  effective byte view and canonical patch identities;
- symbol, type-hint, image, function, budget, and cancellation inputs;
- deterministic, fail-closed byte, symbol, and type-hint providers;
- MacScope-owned DTOs for instructions, address spaces, types, varnodes,
  operations, blocks, edges, SSA, MemorySSA, variables, calls, regions,
  pseudocode tokens, diagnostics, and image-qualified source ranges;
- a structural validator that rejects byte mismatches, cross-image ranges,
  dangling references, malformed ownership/adjacency, invalid SSA/MemorySSA,
  inconsistent variables/types/calls/regions/tokens, and capability lies;
- an untrusted `NativeStructuredProvider` interface wrapped by a validated
  backend that enforces identity stability, deterministic canonicalization,
  budgets, cancellation, elapsed time, and exception sanitization; and
- a direct provider factory enabled only by the explicit verified-package CMake
  option, with unavailable behavior retained for the dependency-free default.

## Raw and effective byte contract

Every `MemoryRegion` contains equal-length `rawBytes` and `effectiveBytes`.
Raw bytes are immutable provenance. Native disassembly, lifting, and
decompilation must consume only `effectiveBytes`. The bridge validates
canonical, strictly ordered, globally unique patch identifiers before exposing
either view.

`AnalysisRequestView::functionBytes()` intentionally aliases the effective
view. Explicit `rawFunctionBytes()` and `effectiveFunctionBytes()` accessors
prevent a future adapter from substituting provenance bytes for the patched
analysis image.

## Validated structured-provider boundary

A provider is not trusted merely because it implements the C++ interface. It
must be wrapped with `makeValidatedProviderBackend`. The wrapper:

- validates availability before analysis and again before publication, while returning a bounded `provider-busy` state instead of blocking status callers behind active analysis;
- requires immutable backend identity and capability claims;
- canonicalizes a private result copy;
- verifies exact instruction bytes and all structured references against the
  request;
- checks capability/output consistency;
- enforces instruction, operation, encoded-size, cancellation, and elapsed-time
  budgets, including worst-case text escaping and byte-array serialization; and
- suppresses third-party exception text.

The in-process wrapper rejects late publication but cannot preempt a blocked
native call. DCP-04 now supplies watchdog invalidation, process termination, and
launchd relaunch at the dedicated signed XPC boundary; the C++ provider itself
still claims only cooperative cancellation, never in-process hard preemption.

## Dependency-free qualification

```sh
cmake -S Tools/NativeDecompilerBridge -B /tmp/macscope-native-contract \
  -G Ninja -DBUILD_TESTING=ON
cmake --build /tmp/macscope-native-contract
ctest --test-dir /tmp/macscope-native-contract --output-on-failure
```

This path performs no dependency acquisition and links no third-party native
code.

## Explicit native SLEIGH package qualification

The approved lifting-bits/sleigh v12.1.2 package is materialized only by:

```sh
./Scripts/dependencies/materialize_sleigh_native_dcp03b4.sh
```

The ignored `sleigh-native-dcp03b4/` result contains `package/` plus a canonical
`MATERIALIZATION.json`. The materializer verifies the release archive, safely
extracts ordinary files, and validates CMake targets, required Ghidra headers,
native libraries, and AArch64 processor resources.

After materialization, the opt-in native API probe is:

```sh
python3 -B Scripts/native-decompiler-direct/verify_sleigh_package.py \
  verify --materialization-root ./sleigh-native-dcp03b4
cmake -S Tools/NativeDecompilerBridge -B /tmp/macscope-native-sleigh \
  -G Ninja -DBUILD_TESTING=ON \
  -DMACSCOPE_ENABLE_SLEIGH_DECOMP_API_PROBE=ON \
  -DMACSCOPE_SLEIGH_MATERIALIZATION_ROOT="$PWD/sleigh-native-dcp03b4"
cmake --build /tmp/macscope-native-sleigh
ctest --test-dir /tmp/macscope-native-sleigh --output-on-failure
```

Before CMake evaluates any upstream package configuration, it executes the independent standard-library verifier over the complete materialization. Linked roots, a changed manifest, altered package files, unknown payloads, or missing governed resources fail before `find_package`. The probe then uses `NO_DEFAULT_PATH`, requires exact version 12.1.2 and the `Specs`
component, links `sleigh::decomp` and `sleigh::sla`, and initializes/shuts down
the native decompiler over the installed processor-specification root. The
probe does not enable a MacScope backend.

## Binding constraints

- `LoadedBinary` remains the application authority for image identity, raw
  segment bytes, preferred/load addresses, slides, address translation,
  symbols, normalized relocations/fixups, and type evidence.
- A direct backend must consume the independently verified effective byte view
  through this seam rather than reopening or reparsing the input binary.
- Rendered pseudocode is presentation output, never semantic input.
- Every capability remains false until corresponding structured records are
  exported directly and independently verified.
- The current Swift decompiler remains the sole default backend.
- DCP-04 hosts the provider only in `NativeDecompilerXPCService`. The app target
  does not link the native package, and no default-backend, persistence, UI, or
  distribution promotion is made.
