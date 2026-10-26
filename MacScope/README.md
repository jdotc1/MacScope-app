# MacScope

MacScope is a native Apple-Silicon macOS binary-analysis workbench for Mach-O
executables, app bundles, dylibs, frameworks, and saved `.mscope` workspaces.
This directory contains the native application source.

## Platform contract

Development and validation require:

- Apple Silicon (`arm64`);
- macOS 27.0 or later;
- a current Xcode 27 toolchain (the Xcode 27 major version is required, but no
  beta, release-candidate, patch, or build number is pinned); and
- the Swift compiler bundled with Xcode 27, with project sources compiled in Swift
  6 language mode.

If Xcode 27 is not the active command-line developer directory, set
`DEVELOPER_DIR` to the installed Xcode 27 developer directory. The application
name may be `Xcode.app`, `Xcode-beta.app`, or another local Xcode 27 installation;
scripts and documentation must not depend on a specific Xcode build number.

Code signing is allowed and required for local app and XPC builds. Use
profileless Manual signing with the exact locally approved Apple Development
identity referenced by the project's signing configuration. The app and all four embedded services—the
Analysis Worker, AI Agent Worker, Native Decompiler, and ShellBroker services—must retain that certificate-backed identity
and the hardened runtime across rebuilds; ad-hoc signing is not the normal
local-development configuration.
Developer ID distribution signing, notarization, and public packaging are
deferred beyond the current roadmap.

## Product-scope highlights

MacScope prioritizes correctness over coverage: an absent or unresolved result
is preferable to one attributed to the wrong image, address domain, process,
module, or analysis revision.

The debugger scope includes launching ARM64 macOS targets and arbitrary local
process attach when macOS policy permits it. Process identity, compatibility,
permission diagnostics, PID-reuse defense, and detach-versus-terminate behavior
are part of that capability. Remote debugging of a process on another system is
explicitly excluded.

The complete binding capability and exclusion record is
[`PARITY_CONTRACT.md`](PARITY_CONTRACT.md).

## Canonical documentation

- [Capability contract](PARITY_CONTRACT.md) — product scope and exclusions.
- [Nomenclature](../docs/brand/Nomenclature.md) — canonical product vocabulary.

## Product defaults and live status

DCP-05 supersedes DCP-04's developer-only, default-off shadow restrictions.
The signed native service provides default-on ARM64 pseudocode and typed reads
for the local assistant. Results are transient and image-qualified, subject to
attestation and validation, with typed degraded states and disclosed fallback.


Historical test receipts apply only to their recorded source identity.

## Repository layout

- `Services/` — loading, analysis, disassembly, decompilation, symbolication,
  debugging, and other analysis services.
- `Models/`, `Stores/`, and `Features/` — state, command, and native SwiftUI /
  AppKit product surfaces.
- `Tests/CoreTests/` and `Tests/Phase2Tests/` — the two hosted test bundles;
  focused selectors name the bundle as well as the suite.
- `project.yml` — XcodeGen source of truth. The generated `.xcodeproj` is
  disposable and must not be hand-edited or committed.
- `../Scripts/` — project generation, tests, validation helpers, and build utilities.

Analysis-layer files shared by the app and Analysis Worker belong in the
`MacScopeAnalysisCore` static library with explicit membership in `project.yml`;
shared debugger-engine files belong in `MacScopeDebuggerCore`. Keep app-coupled
code in the app and preserve the exclusions that avoid compiling shared sources
twice. New shared AI protocol or AI-worker files need the appropriate explicit
worker membership; app-owned Phase 2 authority sources must not enter worker
source sets. Native-decompiler service sources are separately hand-listed under
`NativeDecompilerXPCService`; its native archives and package resources must not
link into `MacScopeApp`. Keep target membership explicit in `project.yml`.

## Build and test

Run from the repository root. This GitHub source line owns the reviewed
Ghostty, Zig, SLEIGH, MachOKit, and XcodeGen inputs. Ordinary bootstrap builds
or reuses verified artifacts in external work roots, without network acquisition:

```zsh
./Scripts/bootstrap.sh
./Scripts/dev_loop.sh --build-only
```

`MacScope/project.yml` is the declarative generation input; the generated
project is disposable and must not be hand-edited or committed. Use the
[root build and test guide](../README.md#build-and-test) for focused selectors,
retained work roots, candidate qualification, and explicit canonical source selection.
Use its [transactional installation procedure](../README.md#transactional-installation)
for an accepted Release candidate. Building does not itself install the app.
Focused iteration uses `Scripts/dev_loop.sh` with `CoreTests/Suite[/case]` or
`Phase2Tests/Suite[/case]` selectors. Reuse accepted checks for unchanged inputs
when selecting validation. Optional external
reference fixtures and historical test receipts must retain their stated scope.

Native decompilation is enabled by default and its launch policy is read once
at app startup. The process environment key
`MACSCOPE_NATIVE_DECOMPILER_ENABLED` overrides the persistent
`nativeDecompiler.enabled` default. Accepted values are `1`, `true`, `yes`,
and `on` for enabled, and `0`, `false`, `no`, and `off` for disabled. An
unrecognized environment value falls back to the enabled product policy.
Override the persistent default with
`defaults write org.macscope.app nativeDecompiler.enabled -bool false`, then
fully quit and relaunch MacScope. Remove the override with
`defaults delete org.macscope.app nativeDecompiler.enabled`. Observe
privacy-safe native-runtime metadata with:

```zsh
log stream --style compact \
  --predicate 'subsystem == "org.macscope.MacScope" AND category == "NativeDecompiler"'
```

For installation, follow the root README's transactional guide.
A historical installation receipt does not establish the current installed version.
