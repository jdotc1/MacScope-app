# GhosttyKit derived-artifact contract

GST01-F2 builds the reviewed repository-owned patched source into one private,
untracked `GhosttyKit.xcframework`. Source inputs are tracked under
`ThirdParty`; Zig caches, the build snapshot, framework, archive, and manifest
remain in the caller's explicit external work root.

The normal self-contained build entrypoint is
`Scripts/dependencies/build_vendored_ghostty_surface.sh --work-root
<absolute-external-root>`. It accepts no source, package-store, or toolchain
path and performs no network access. It verifies the frozen source tree,
package-store digest, and Zig receipt before snapshotting into the owned
`GhosttySurface` child of that work root. The lower-level
`Scripts/dependencies/build_ghostty_surface.sh` then requires the exact patched
Git tree and Zig 0.16.0, uses the frozen `app-runtime=none`, native arm64,
ReleaseFast Metal XCFramework flags, explicitly disables Sentry/Breakpad and
internationalization, disables the root Zig networking capability, and selects the dedicated `macscope-xcframework` graph
edge instead of Ghostty's default install graph. Therefore app/executable/test,
docs, terminfo/termcap, shell-integration, completion, syntax, translation,
theme, and web-data payloads are not built or emitted. The entrypoint never runs
from ordinary bootstrap or Xcode
build phases. The build uses Zig system-package mode against the repository-owned
closed `zig-pkg` store copied into the external snapshot, so missing
dependencies fail rather than fetch. `--verify-only` performs no build or
dependency acquisition.

Acceptance requires:

- XCFramework library identifier `macos-arm64`;
- arm64-only `libghostty-internal.a`;
- `ghostty.h` and `module.modulemap`;
- external-I/O ABI version 1 in the header;
- all four v1 external-I/O symbols in the archive; and
- no Sentry, Crashpad, or Breakpad symbols in the archive; and
- no direct libxev network imports and no resolver imports; and
- exactly the five Zig 0.16.0 root-I/O-vtable residual imports `_bind`,
  `_connect`, `_listen`, `_recvmsg`, and `_socket`, all owned by
  `libghostty_zcu.o`; and
- a manifest binding source revision/tree/digest, Zig version, ABI version,
  raw/patched package identity, libxev patch, the disabled-network capability,
  the frozen residual-import set, exact build profile, architecture, slice
  identifier, and SHA-256 values for the Info.plist, archive, header, and
  module map.

The wrapper reports these stable seams after either build or verification:

- source/build snapshot: `<work-root>/GhosttySurface`;
- artifact root: `<work-root>/GhosttySurface/macos/GhosttyKit.xcframework`;
- archive: `macos-arm64/libghostty-internal.a` beneath the artifact root;
- C header and module map: `macos-arm64/Headers/ghostty.h` and
  `macos-arm64/Headers/module.modulemap`; and
- schema-3 manifest:
  `<work-root>/GhosttySurface/macos/.macscope-ghostty-surface-manifest`.

GhosttyKit does not receive process or PTY authority through this build seam.
