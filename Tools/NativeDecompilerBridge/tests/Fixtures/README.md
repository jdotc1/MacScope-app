# DCP-03B5 source fixtures

These deterministic, source-only fixtures exercise the direct native structured
provider. The test harness compiles them into its CMake build directory, derives
function extents and effective bytes there, and never commits objects, Mach-O
files, archives, extracted bytes, or compiler-build-specific expectations.

## Source inventory

| File | Exported function(s) | Intended provider evidence |
|---|---|---|
| `c_effective_bytes.c` | `macscope_fixture_effective_bytes` | Conditional flow plus a patchable branch/call whose effective bytes may diverge from raw provenance. |
| `c_control_flow.c` | `macscope_fixture_straight_line`, `macscope_fixture_conditional`, `macscope_fixture_loop`, `macscope_fixture_switch` | Straight-line flow, branch/join, loop, and multiway switch/CFG coverage. |
| `c_ssa_memory.c` | `macscope_fixture_register_widths`, `macscope_fixture_zero_register`, `macscope_fixture_join_phi`, `macscope_fixture_stack_local`, `macscope_fixture_global_access`, `macscope_fixture_memory_alias` | `wN`/`xN` width behavior, zero-register materialization, join heritage, stack/global memory, and conservative alias handling. |
| `c_calls.c` | `macscope_fixture_direct_target`, `macscope_fixture_direct_call`, `macscope_fixture_indirect_call`, `macscope_fixture_call_chain` | Direct and indirect call records, caller symbol/type hints, and patched call targets. |
| `c_large_budget.c` | `macscope_fixture_large_budget` | A bounded, operation-heavy function for incremental count/output/time budget rejection. |
| `objc_dispatch.m` | `macscope_fixture_objc_dispatch` | Objective-C message dispatch and the `default` compiler specification. |
| `cpp_virtual.cpp` | `macscope_fixture_cpp_virtual_dispatch`, `macscope_fixture_cpp_direct_dispatch` | C++ virtual/indirect dispatch and direct comparison flow. |
| `swift_calls.swift` | `macscope_fixture_swift_direct_target`, `macscope_fixture_swift_direct_call`, `macscope_fixture_swift_indirect_call`, `macscope_fixture_swift_branch` | Swift direct/indirect calls, branch flow, and the `swift` compiler specification. |

Helper functions and class methods intentionally remain in the same source
objects so the harness can map broader caller-owned effective memory while
requesting one exact exported function extent at a time.

## Intended compile contract

The provider tests use only the current Xcode 27 bundled compilers, target
native Apple Silicon and macOS 27, and place every derived object, linker map,
Mach-O, extracted byte buffer, and generated driver under the active CMake
build directory. Set the toolchain and SDK explicitly:

```sh
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
SDK="$(xcrun --sdk macosx --show-sdk-path)"
CC="$(xcrun --find clang)"
CXX="$(xcrun --find clang++)"
SWIFTC="$(xcrun --find swiftc)"
```

The qualified compile flags are:

```text
C:          clang -target arm64-apple-macos27.0 -isysroot "$SDK" -std=c17 -O1 -g0 -fno-inline -fno-optimize-sibling-calls -fno-stack-protector -fvisibility=hidden
Objective-C: clang -target arm64-apple-macos27.0 -isysroot "$SDK" -std=c17 -O1 -g0 -fno-inline -fno-optimize-sibling-calls -fno-stack-protector -fvisibility=hidden -fno-objc-arc
C++:        clang++ -target arm64-apple-macos27.0 -isysroot "$SDK" -std=c++20 -O1 -g0 -fno-inline -fno-optimize-sibling-calls -fno-stack-protector -fvisibility=hidden -fno-exceptions -fno-rtti
Swift:      swiftc -target arm64-apple-macosx27.0.0 -sdk "$SDK" -swift-version 6 -parse-as-library -O -whole-module-optimization -num-threads 1 -module-name MacScopeDCPFixtureSwift -enable-deterministic-check -emit-object
```

Link every executable with `-Wl,-reproducible`, `-Wl,-data_const`, and a unique
build-directory map such as `-Wl,-map,"$OUT/c.map"`. Pass the corresponding
options to `swiftc` as `-Xlinker` arguments. Retain the linker's deterministic,
content-derived `LC_UUID`; do **not** use `-Wl,-no_uuid`, because macOS 27 dyld
rejects a launchable arm64 executable without `LC_UUID`. The normal linker
generated ad-hoc signature is permitted for these build-only executables.

The normal C, Objective-C, and C++ fixtures use `-O1`. Compile a second copy of
`c_control_flow.c` with the otherwise identical flags but `-Oz` and link it as
a dedicated switch fixture. Xcode 27 lowers the `-O1` switch to a comparison
tree, while the qualified `-Oz` build produces `BRANCHIND` plus an eight-entry
jump table. Both forms are useful and must remain distinct fixtures.

Do not add source paths, build timestamps, randomized instrumentation,
sanitizers, coverage instrumentation, or link-time optimization to the
canonical fixture identity. Sanitizer configurations qualify the provider and
test harness; they do not redefine the compiled fixture bytes.

## Function extents and byte authority

The linker's atom record is the exact function-extent authority. Parse each
generated map's address and size for the requested symbol and use the resulting
half-open interval. Never infer an extent from the next symbol: alignment gaps
exist, and the next symbol may be data or a helper owned by a different
function.

The caller-side harness maps the linked Mach-O into caller-owned effective
memory before invoking the provider. That mapping must be contiguous across
every address the architecture may validly read, including call targets,
literal pools, and the `-Oz` switch's `__TEXT,__const` jump table beyond the
requested function extent. The request still names one exact function range,
and the provider must reject instructions or blocks outside it. The harness
must not pass a fixture path to the provider, and the provider must never open
or parse the Mach-O.

For Swift, the exported `@_cdecl` symbols are four-byte branch thunks whose
targets lie outside the thunk extents. Analyze the adjacent mangled Swift
implementation bodies with compiler specification `swift`; do not analyze the
`@_cdecl` thunks or broaden their ranges. Derive those body symbols and extents
from the current map rather than pinning compiler-build-specific manglings or
addresses.

All fixture identities and expectations are derived during the current build.
Never track or pin objects, executables, archives, extracted bytes, absolute
addresses, `LC_UUID` values, SHA-256 values, or Xcode-build-specific linker
maps. Provider determinism is asserted over MacScope-owned DTOs produced from
the same caller-owned fixture bytes, not over a permanent compiler-artifact
golden.

## Qualification matrix

| Fixture | Compiler spec | Qualified provider evidence |
|---|---|---|
| C straight line and conditional | `default` | Exact instructions and p-code, true/false CFG polarity, join, source ranges, and mandatory SSA bindings. |
| C loop | `default` | Backedge, loop blocks, join/heritage evidence, and deterministic graph ordering. |
| Dedicated C `-Oz` switch | `default` | `BRANCHIND`, case/default edges, and a jump-table read outside the exact function but inside caller-owned effective memory. |
| C direct call, indirect call, and call chain | `default` | Direct `CALL`, targetless `CALLIND`, external call edges, caller symbol precedence, and patched call targets. |
| C register widths, zero register, and join phi | `default` | `wN`/`xN` semantics, conservative zero-register handling, and native heritage without overclaiming complete register SSA. |
| C stack, global, and alias memory | `default` | Stack/global LOAD/STORE spaces and conservative alias behavior; MemorySSA remains false until separately proven complete. |
| C effective-byte fixture | `default` | Raw/effective divergence and a patched branch or call changing native behavior. |
| C large-budget fixture | `default` | Incremental instruction, operation, encoded-output, and elapsed-budget rejection. |
| Objective-C dispatcher | `default` | Selector-stub call and Objective-C caller-symbol evidence. |
| C++ virtual and direct dispatchers | `default` | Vtable/global reads, indirect virtual call, and explicit constructor/method calls. |
| Swift mangled implementation bodies | `swift` | Direct and indirect calls plus conditional flow under the exact Swift compiler specification. |

`c_large_budget.c` deliberately uses volatile storage. It is not a timing
benchmark; it provides a reproducible large structured graph so the provider
can prove fail-closed incremental budget handling.
