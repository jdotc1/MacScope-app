# MacScope debugging playbook

This file keeps reusable development methods, not incident chronology. Current
scope and sequencing live in the [capability contract](../../MacScope/PARITY_CONTRACT.md)
and [Nomenclature](../brand/Nomenclature.md) owns
product vocabulary.

MacScope targets Apple Silicon, macOS 27.0 or newer, the current Xcode 27 major
line, and its bundled Swift compiler in Swift 6 language mode. Do not pin a
transient Xcode build unless reproducing a build-specific defect.

## Canonical entry points

The repository owns its reviewed dependency sources and tools. Bootstrap and
qualification are offline and publish generated artifacts only to external
work roots.

```zsh
# Generate the disposable project and build/reuse offline dependency outputs.
./Scripts/bootstrap.sh

# Run the authoritative test target or a focused selector.
./Scripts/test.sh
./Scripts/test.sh CoreTests/SomeSuite
./Scripts/test.sh CoreTests/SomeSuite/someCase

# Qualify a sealed candidate from the verified canonical GitHub mirror in an external root.
./Scripts/qualify_local_private_build.sh \
  --work-root /absolute/external/macscope-focused \
  --integration-ref refs/remotes/github/main \
  --mode focused-test \
  --only-testing CoreTests/SomeSuite/someCase
```

Verify that `github` resolves to the canonical repository and its `main` tracking
ref is current before using the example; remote names are host-specific.

`MacScope/project.yml` is authoritative; never hand-edit or commit the generated
`MacScope/MacScope.xcodeproj`. Worker/service targets use explicit source lists,
so a new shared file must be added deliberately. Keep Derived Data and every
dependency/build work root outside the repository.

Local app and XPC evidence requires the tracked Apple Development identity,
manual profileless signing, and hardened runtime. Ad-hoc signing is not an
equivalent local result. Verify a built candidate with the repository signing
checker and strict/deep `codesign`, not visual inspection.

Native pseudocode is default-on and read once at app startup. The
`MACSCOPE_NATIVE_DECOMPILER_ENABLED` environment key overrides the
`nativeDecompiler.enabled` Boolean default. Fully quit and relaunch after a
policy change. Stream only bounded operational records:

```zsh
log stream --style compact \
  --predicate 'subsystem == "org.macscope.MacScope" AND category == "NativeDecompiler"'
```

## Debugger transport decision

Production debugging retains the hardened persistent LLDB CLI transport. The
Xcode `lldb-dap` and Xcode-bundled Python/LLDB bridges remain tooling and future
migration candidates; neither proved the complete live module/thread/frame/
register/memory/breakpoint/step/cancellation/recovery identity matrix required
to replace the primary transport. Do not create a second-session hybrid.

Local ARM64 launch and explicit exact-process attach are supported through the
current transport. Detach must not terminate the target. Remote host/port,
GDB-remote, network listeners, and remote-process debugging remain excluded. A
future transport migration needs a versioned spec, current-Xcode evidence,
runtime-derived identifiers, same-session console behavior, and independent
validation.

## Techniques

| Technique | Procedure | Acceptance |
| --- | --- | --- |
| Prove the environment first | Record Xcode/SDK/Swift/host/architecture, effective signing, entitlements, and the exact candidate ref before editing code. | The first actionable environment difference is explicit; it is not disguised as a product fix. |
| Bootstrap before discovery claims | Run bootstrap, inspect the generated target membership, then execute the exact test selector. | The expected test executes; zero tests is not green. |
| Use an external oracle | Compare normalized output with an authorized primary tool such as `otool`, `clang`, `swift-demangle`, `c++filt`, or `dwarfdump`. | Unsupported non-nil output is a defect; absence is safer than a wrong claim. |
| Prove a regression fixture can fail | Run it against pre-fix behavior, then against the correction. | The assertion turns red for the intended reason and green only with the fix. |
| Harden every untrusted read | Use exact conversions, checked arithmetic, validated ranges, bounded collections/loops, and conservative abstention. | Overflow, truncation, aliasing, malformed nesting, and oversized-count cases are covered. |
| Preserve qualified identity | Carry image/workspace/window/session/process/function/revision identity through bindings, callbacks, tasks, and persistence. | Same-VA and stale-completion cases cannot select, publish, navigate, or mutate a sibling owner. |
| Force cancellation and lifecycle races | Exercise cancel, owner change, epoch/generation change, teardown, late reply, and retry on the real actor/queue boundary. | Stale work is observed and rejected; shutdown is bounded and leaves no residue. |
| Version and round-trip persistence | Test old-to-current migration and save/load/save identity with reanalysis carry-over. | No silent loss, cross-image rebinding, or migration-only success. |
| Bound destructive debugger tests | Spawn the fixture, capture PID/executable/parentage, act only on that exact owned process, and prove cleanup. | No unrelated process can be targeted; detach is non-killing; zero owned residue remains. |
| Measure before optimizing | Measure the actual workload and retain before/after evidence plus the unmeasured tail. | The claimed hot path improves without weakening correctness or coverage. |

## Split ambiguous symptoms

- UI identity: reproduce the selected/focused model without presentation, then
  inspect view identity, focus, callbacks, and accessibility.
- Analysis: compare the exact bytes and normalized semantic result with an
  authorized oracle.
- Persistence: run a schema-aware round trip and reanalysis carry-over.
- Concurrency: force cancellation, owner/generation change, and late completion.
- Debugger: separate configured target, live process, session, stop revision,
  module UUID/load address, and static image identity.
- Terminal: separate ShellBroker process/PTY state, accepted transcript,
  renderer generation, full-surface health, and legacy-grid recovery.
- Environment: prove current Xcode 27, SDK 27, arm64, signing, entitlements,
  dependency identities, and the same command on the sealed candidate.

Record the eliminated buckets and the evidence that eliminated them. Narrow
hypotheses prevent cross-layer repairs and unnecessary broad reruns.
