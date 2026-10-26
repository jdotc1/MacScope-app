# Ghostty external-I/O patch record

MacScope carries a narrow five-commit patch series over Ghostty
`f64f4aca2c29b554d111b36c3d946a9bddd159ff`. It adds a host-fed terminal
backend and private size-prefixed C ABI v1 without giving Ghostty ownership of
a process, PTY, terminal file descriptor, signal, resize ioctl, or wait.

## Patch series

| Patch | SHA-256 | Purpose |
|---|---|---|
| `0001-test-gst-define-external-termio-ABI-and-backend-cont.patch` | `5163ba711bd700e233d8b4ad5bfab137dd1aaaa5f4f2362e7746e6c55e0fe2cf` | Freeze ABI v1, bounded shared state, lifecycle, registry, and fail-closed tests. |
| `0002-feat-gst-add-host-fed-external-termio-backend.patch` | `cf57e88edc48fb9edc74f02f2c3446f4fcabe9b2ef6f86aa44a7de629bc9eca2` | Wire `.external` through Surface, embedded apprt, Termio, callbacks, queues, and C exports. |
| `0003-test-gst-harden-external-backend-ordering-and-lifecy.patch` | `0ce86d6ba97f679f3857c784e173f71806e7bf3896a06338196f999ecb789045` | Repair output-readiness retry and pre-allocation admission; harden semantic, final-frame, concurrent destruction, and bounded real-thread coverage. |
| `0004-build-gst-add-external-I-O-only-XCFramework-step.patch` | `191bd9acbc86fd6621b8fe9e2a6e64a53125670861a31d36d66e870b179a4c58` | Add an explicit XCFramework-only build edge that excludes application resources and install payloads. |
| `0005-build-gst-disable-root-networking-in-external-only.patch` | `632d6b96c68da1f0286c47c9a5d19613caa2ff485d1ccefc911ed2c6d748f2a5` | Set the root Zig networking capability to false only for the private external-I/O artifact and freeze that relationship with an upstream test. |

The closed package store carries one separately reviewed transitive patch:

| Package patch | SHA-256 | Purpose |
|---|---|---|
| `libxev-networking-capability.patch` | `f26b438413c1ec2022f5e6701daa8d00920c91bc7da9f6add5d2e80662e0ff8d` | Make every libxev POSIX/kqueue socket entry point fail closed when the root Zig networking capability is disabled. |

The store also carries the same metadata-only Windows-line-ending closure as
the raw Ghostty VT store: the vendored package's final `.gitattributes` rules
mark `*.sln`, `*.vcxproj`, `*.vcxproj.filters`, and `*.natvis` as `-text` so the
46 reviewed CRLF leaves survive Git and Git-less sealed source export exactly.

The exact changed upstream paths are:

- `build.zig`
- `include/ghostty.h`
- `src/Surface.zig`
- `src/build/Config.zig`
- `src/main_ghostty.zig`
- `src/apprt/embedded.zig`
- `src/apprt/none.zig`
- `src/termio.zig`
- `src/termio/External.zig`
- `src/termio/backend.zig`

## Repository metadata normalization

The upstream patched Git tree is
`b6aad1ba32602ee4eb3ea96fd88116a49ed09e97`. Before vendoring, MacScope
normalizes the single upstream `CLAUDE.md` symbolic link into an ordinary file
whose bytes are identical to its `AGENTS.md` target. Both ordinary files have
SHA-256 `4939dae26b5551d1aee737e4cdae126499a1051585c8e72768c0b79f0b857121`.

This metadata-only normalization is required by MacScope's fail-closed
third-party inventory policy, which prohibits symbolic links in governed
source trees. It changes no source bytes, compiled semantics, patch-series
path, or length-framed source digest. The resulting repository snapshot Git
tree is `de6cd65b35a423d5d6854c6af3a90be20a52d7eb`, with length-framed source
SHA-256 `ead5d48a8cda07addb59af1f35c6c9f7226bbdbd977b7330afd9714ecec6d8ab`;
that is the source identity produced by the amended series.

## Contract

The four new exports are `ghostty_surface_new_external`,
`ghostty_surface_external_feed`,
`ghostty_surface_external_set_process_state`, and
`ghostty_surface_is_external_io`. The complete callback, queue, threading,
backpressure, teardown, and forward-compatibility contract is recorded in
`ABI_CONTRACT_V1.md`.

Inbound data is bounded to 1 MiB and 1,024 chunks. Pending terminal-generated
output is bounded to 256 KiB. The external-surface registry is bounded to 64
surfaces. Feeds are all-or-nothing; retained bytes are copied before return;
callbacks run on the Termio I/O thread with no internal lock held and cannot
occur after surface destruction returns.

## Apply and verify

```sh
./Scripts/dependencies/materialize_ghostty_surface.sh <external-destination>
```

The materializer requires the unpatched tree and digest recorded in
`SOURCE_TREE_SHA256`, applies the five ordered Ghostty patches with ordinary
`git am`, and requires the exact patched tree and digest. GST-01 Task 8 did
not own materializer, builder, or frozen-identity consumers; integration must
advance those consumers to the amended patch hash and source identities above
before invoking replay. The materializer then verifies and copies the raw
closed Zig package store, applies the libxev patch with zero-fuzz `patch`, and
requires the exact patched package-store digest before publishing the
destination.

The resulting reviewed snapshots are checked in at
`ThirdParty/GhosttySurface/Source` and
`ThirdParty/GhosttySurface/zig-pkg`. Normal development does not replay or
download this patch series. It verifies and builds the repository-owned closure
with:

```sh
./Scripts/dependencies/build_vendored_ghostty_surface.sh \
  --work-root /absolute/external/work-root
```

All derived output is written below the external work root. The checked-in
source and package snapshots remain immutable build inputs.

With networking disabled, `getaddrinfo` and the direct libxev socket surface
are absent from the archive. Zig 0.16.0 nevertheless emits five unreachable
POSIX imports (`bind`, `connect`, `listen`, `recvmsg`, and `socket`) from its
root `std.Io.Threaded` vtable. The artifact verifier freezes that exact inert
set and its owning archive member; any additional network import fails closed.
Patching the pinned Zig toolchain merely to erase unreachable vtable entries
is deliberately out of scope for this bounded Ghostty/libxev correction.

GST-01 Task 8 qualification reported 104/104 focused external tests. The
earlier full-suite qualification remains 3,354/3,370 tests passed with 16
authorized skips and zero failures; Task 8 did not rerun that broad gate.
MacScope independently replayed the amended five-patch series from the pinned
baseline and reproduced the exact source bytes and identities above before
accepting these files.

## Rollback

Omit this isolated patch series, transitive libxev patch, and full-surface materialization. The existing
`ghostty-vt` dependency and legacy MacScope grid remain separate and unchanged.
