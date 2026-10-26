# Ghostty VT local patch record

MacScope does not patch Ghostty implementation code. `Source/` contains the
reviewed upstream ordinary-file snapshot plus repository-container metadata
changes that preserve the closed package bytes. `Source/.gitattributes` ends in
`zig-pkg/** -text`. One vendored package contains a deeper `.gitattributes`, so
its final four Windows metadata rules are repeated as `-text` for `*.sln`,
`*.vcxproj`, `*.vcxproj.filters`, and `*.natvis`. This prevents Git's clean
filter from normalizing 46 intentional CRLF files before a sealed source export.

To reverse the metadata patches, remove the final comment and `zig-pkg/** -text`
line from `Source/.gitattributes` and the final MacScope block in the vendored
package `.gitattributes`. Do not do so while `zig-pkg` is vendored; clean
checkouts and Git-less sealed exports would diverge and fail the frozen identity.

`Source/CLAUDE.md` is an ordinary byte-identical copy of `Source/AGENTS.md`.
The upstream Git tree represents it as an alias, but MacScope's accepted source
closure and third-party validator prohibit symlinks. This normalization was
already present in the accepted local snapshot and is retained here explicitly.

The repository-owned builder invokes `-Demit-lib-vt` and
`-Demit-xcframework=false`, supplies the package store with `--system`, and
redirects the install prefix and both Zig caches to the caller's external work
root. MacScope consumes only the generated arm64 macOS
`libghostty-vt.dylib`, C header, module map, and governed manifest.

The MacScope integration selects Ghostty's scalar VT build by default through
`MACSCOPE_GHOSTTY_SIMD=false`. This is a build option, not an upstream source
modification. Any future source patch must be recorded here with:

1. the exact upstream revision;
2. a checked-in patch file and SHA-256;
3. the reason the adapter cannot avoid the patch;
4. deterministic apply and reverse procedures; and
5. qualification and rollback evidence.
