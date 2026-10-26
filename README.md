<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/brand/app-icon-dark.png">
    <img src="docs/brand/app-icon-light.png" width="128" height="128" alt="MacScope app icon">
  </picture>
</p>

<h1 align="center">MacScope</h1>

<p align="center">
  <strong>A native Apple-silicon macOS workspace for understanding binaries.</strong><br>
  Move between disassembly, ARM64 pseudocode, graphs, and bytes while keeping findings tied to the right image.
</p>

MacScope brings static inspection, annotations, local debugging, and durable
workspaces into a SwiftUI/AppKit application. Its primary focus is Mach-O on
macOS, with ELF and PE loading for cross-format static inspection. Use it to
investigate your builds, understand compiler output, and keep evidence and notes
with the code they describe.

**[Build and test](#build-and-test)** ·
**[Python client](MacScope/python/README.md)** ·
**[Capability contract](MacScope/PARITY_CONTRACT.md)**

> [!IMPORTANT]
> This repository contains MacScope source code. Build locally with the documented
> toolchain and configure signing for your development environment.

## The workspace

| Task | Product surface |
| --- | --- |
| Follow code across views | Coordinated Disassembly, Pseudocode, Graph, and Hex editors. |
| Inspect a binary's structure | ARM64/x86_64 disassembly, symbols, imports/exports, relocations, chained fixups, code signatures, Objective-C/Swift metadata, and DWARF/dSYM evidence. |
| Read ARM64 pseudocode | Native SLEIGH-backed decompilation through a signed embedded XPC worker, with structured attribution and a disclosed MacIR fallback. |
| Record an investigation | Local labels, comments, types, bookmarks, annotations, and `.mscope` workspaces. |
| Work with changes and runtime evidence | Byte patches, assembly, patched-binary export, and LLDB-backed local ARM64 launch/attach, within the documented product and platform limits. |
| Integrate a local workflow | App-owned JSON, MCP, Python-client, debugger, shell/terminal, and local-model surfaces, with separate authority boundaries. Reconstruction workspaces retain evidence and checkpoint identity. |

A workspace can contain multiple images. Addresses, runtime observations, and
delayed results keep their image/session identity. Missing evidence is represented
as unavailable or degraded; source presence alone is not a claim of validation
or full capability coverage.

## Platform and supported scope

| Contract | Scope |
| --- | --- |
| Host | Apple silicon, macOS 27.0 or newer. |
| Toolchain | Xcode 27 major line, its bundled Swift compiler in Swift 6 mode, and bundled LLDB. |
| Static architectures | ARM64 and x86_64. |
| Primary inputs | Mach-O files and containers, app bundles, frameworks, dylibs, XPC services, universal files, and dyld-cache images. |
| Cross-format inspection | ELF and PE static inspection. |
| Pseudocode and debugger | ARM64 pseudocode and local ARM64 launch/attach. Process availability remains subject to macOS signing and authorization policy. |
| Workspace format | `.mscope` package. |
| Local signing | The repository's approved certificate-backed Apple Development identity, manual profileless signing, and hardened runtime. |

Xcode 27 beta, RC, and patch revisions are accepted by the platform contract;
no transient Xcode build number is the product requirement. Set `DEVELOPER_DIR`
when the desired Xcode 27 installation is not the active developer directory.

The [capability contract](MacScope/PARITY_CONTRACT.md) defines inclusions,
explicit exclusions, and acceptance vocabulary. In particular, x86_64 static
inspection does not imply x86 decompilation or debugging, and local debugging
does not imply remote debugging.

## Build and test

Work in the maintainer's prepared development environment with the pinned
dependency inputs and approved local signing identity. Run commands from the
repository root. Keep build outputs in a dedicated external work root.

Generate the Xcode project and build the development target:

```zsh
./Scripts/bootstrap.sh
./Scripts/dev_loop.sh --build-only
```

The generated `MacScope/MacScope.xcodeproj` is disposable.
[MacScope/project.yml](MacScope/project.yml) is the source of truth; regenerate
when project membership changes and keep generated projects out of commits.

For iteration, `Scripts/dev_loop.sh` retains DerivedData per worktree/toolchain,
reuses the verified dependency cache, and accepts focused selectors in the form
`CoreTests/Suite[/case]` or `Phase2Tests/Suite[/case]`. Its `--help` describes the
available modes. Select only the affected checks and reuse accepted results when
their inputs are unchanged. A selector identifies the test bundle as well as the
suite. The script coordinates heavy build work through the shared gate lock.

`Scripts/test.sh` remains an explicit test driver and defaults to the full
CoreTests bundle when called without a selector. Developer-loop output is
iteration evidence, not a Release, CI, or qualification result. The
[debugging playbook](docs/dev/DebuggingPlaybook.md) provides troubleshooting
context; use the current repository rules for the appropriate verification scope.

### Qualify a candidate

GitHub `main` is the canonical integration source. Verify the remote URL and
update its tracking ref before selecting the source. Existing workstations may
use `github`; a fresh clone may name the same URL `origin`. Select by verified
repository identity rather than remote name alone.

The canonical qualifier takes an explicit integration ref and an absolute
external work root:

```zsh
./Scripts/qualify_local_private_build.sh \
  --work-root /absolute/external/macscope-candidate \
  --integration-ref refs/remotes/github/main \
  --mode prepare
```

`smoke`, `focused-test --only-testing CoreTests/Suite/case`, `full-test`, and
`release` are available for their corresponding gates. Choose the mode required
by the current task and reuse its retained root and evidence. Capture the printed
receipt, source commit/tree, dependency roots, DerivedData, and product path.
A successful build, selected test, or launch is not a full qualification result.

Ordinary qualification omits `--materialize-dependencies`; the repository-owned
closure supports offline build work. Dependency acquisition is a separate
explicit step. Handle tooling failures at their source using the existing run context.

## Transactional installation

Installation is a separate step for a qualified Release candidate. Use the
canonical **`Scripts/install_local_private_build.sh --mode installed-acceptance`**
route. Its help describes source selection, candidate identity, predecessor
observations, qualification run identity, evidence paths, and final acceptance.

The entry point delegates the complete begin/gates/commit-or-rollback lifecycle
to the transaction driver. The driver preserves the predecessor and binds the
installed signing, native-XPC, terminal/shell, GUI, CLI, and MCP evidence to the
candidate. It produces and validates the required eight transaction envelopes
before committing, or follows the governed rollback path on failure.

Use the transaction-owned outputs and exact candidate identity; do not assemble
acceptance envelopes by hand or treat a historical installation receipt as proof
of the current installed version. A local installation does not authorize public
distribution or establish a broader program gate.

## Runtime controls and automation

Native pseudocode is enabled by product policy, read once at startup. The
`MACSCOPE_NATIVE_DECOMPILER_ENABLED` environment key overrides the
`nativeDecompiler.enabled` Boolean in the `org.macscope.app` defaults domain.
Trimmed, lowercased `1`, `true`, `yes`, and `on` enable it; `0`, `false`, `no`,
and `off` disable it. An unrecognized environment value falls back to enabled.
Fully quit and relaunch after changing either setting.

Observe privacy-safe native-worker operational metadata with:

```zsh
log stream --style compact \
  --predicate 'subsystem == "org.macscope.MacScope" AND category == "NativeDecompiler"'
```

The built executable exposes headless JSON and MCP entry points for a selected
binary:

```zsh
/path/to/MacScope.app/Contents/MacOS/MacScope --run-script /path/to/script.json /path/to/your-build
/path/to/MacScope.app/Contents/MacOS/MacScope --mcp /path/to/your-build
```

The dependency-free [Python client](MacScope/python/README.md) documents the
client API, deadlines, transport limits, and failure semantics. Its headless
session edits are undoable in memory and are not persisted as a saved workspace.

MTPLX is the supported local inference integration. It owns model loading and
context management; MacScope retains endpoint/model selection, bounded requests,
result validation, and tool authorization. A configured endpoint or desired
model name is not evidence that the runtime is ready. Runtime/model evidence
cannot overwrite static source authority.

## Architecture and trust boundaries

`LoadedBinary` is the authority for image identity, addresses, and bytes. The app
owns authorization, accepted evidence, persistence, and final presentation.
Workers return bounded MacScope-owned data structures within their assigned
roles; they do not inherit the app's authority.

| Component | Responsibility and boundary |
| --- | --- |
| App and workspace | Policy, commands, durable state, evidence acceptance, and presentation. |
| Analysis worker XPC | Isolated loading/analysis and metadata/export operations. Native parser objects remain behind MacScope-owned interfaces. |
| Native decompiler XPC | SLEIGH-backed ARM64 pseudocode and validated transient structured results. Native decompiler objects do not enter the app process or persistence. |
| AI-agent worker XPC | Bounded work through the qualified local provider and the app's declared authorization path. |
| ShellBroker XPC and LaunchAgent | Processes and PTYs. Ghostty provides terminal parsing, rendering, selection, and input encoding, with a pinned VT fallback. |
| LLDB transport | Local debugger interaction with process/session identity and explicit lifecycle handling. |

Model output cannot bypass the human-input command path. Native engines retain
bounds, cancellation, watchdogs, and crash isolation.

## Dependency and source ownership

The repository owns the reviewed Ghostty VT/full-surface snapshots, Zig
toolchain/package-store closure, SLEIGH/Ghidra source and processor resources,
MachOKit, SwiftAssembly fallback, and XcodeGen. The pinned first-party Lumen
package is tracked separately in [FIRST_PARTY_COMPONENTS.json](FIRST_PARTY_COMPONENTS.json).

Immutable pins, checksums, patches, licenses, and notices live in the relevant
`Scripts/*.contract` files, [THIRD_PARTY_COMPONENTS.yml](THIRD_PARTY_COMPONENTS.yml),
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md), and [ThirdParty](ThirdParty/).
Bootstrap and qualification build or reuse verified artifacts under external
work roots without downloading dependencies. Diagnostic overrides must satisfy
the same validators. Keep generated artifacts, caches, DerivedData, signed
products, and install transactions out of the repository.

The [dependency workflow](docs/dependencies/DependencyWorkflow.md) covers acquisition, integration, pinning, and rollback. Local builds retain
certificate-backed signing and hardened runtime; the isolated CI lane has its
own signing treatment. Developer ID distribution and notarization are separate
product decisions.

## Repository guide

| Path | Purpose |
| --- | --- |
| [MacScope](MacScope/README.md) | App source, worker targets, models, services, workspace state, and tests. |
| [MacScope/project.yml](MacScope/project.yml) | XcodeGen project and source-membership authority. |
| [Scripts](Scripts/) | Development loop, dependencies, qualification, controlled installation, and focused checks. |
| [Nomenclature](docs/brand/Nomenclature.md) | Canonical product vocabulary. |

## Distribution and rights

Copyright 2026 the MacScope authors. All rights reserved. No open-source license is granted at this time. Third-party components retain their own licenses and notices.
