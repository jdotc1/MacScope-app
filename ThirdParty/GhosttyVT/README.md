# Repository-owned Ghostty VT source

MacScope vendors the complete reviewed Ghostty source snapshot and its closed
Zig package store under `Source/`. Normal builds therefore require no external
Ghostty checkout, package seed, or network acquisition. The exact upstream
revision and content identities are recorded in `PROVENANCE.md` and
`Scripts/ghostty-vt-source.contract`.

`Scripts/build_ghostty_vt.sh` consumes these repository inputs together with
the repository-owned Zig 0.16.0 toolchain. The caller must supply an absolute
external directory through the required `--work-root` argument. The stable
output seam is:

- `<work-root>/artifacts/lib/libghostty-vt.dylib`
- `<work-root>/artifacts/include/ghostty/vt.h`
- `<work-root>/artifacts/include/module.modulemap`
- `<work-root>/artifacts/lib/.macscope-ghostty-vt-manifest`

Zig's local cache, global cache, SDK compatibility overlay, and every generated
artifact also remain below that work root. `Source/.zig-cache` and
`Source/zig-out` are rejected so normal builds cannot dirty the vendored source.

The build remains intentionally narrow: scalar arm64 macOS `libghostty-vt`, its
C header, and module map. It does not emit the Ghostty app, an XCFramework, iOS
or Simulator products, or a universal static library.
