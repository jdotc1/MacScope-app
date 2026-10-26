# Repository-owned Zig toolchain provenance

MacScope carries the official Apple-Silicon Zig 0.16.0 toolchain as a normal
repository input at `ThirdParty/Zig/zig-0.16.0`. It was derived without local
patches from:

- archive URL:
  `https://ziglang.org/download/0.16.0/zig-aarch64-macos-0.16.0.tar.xz`;
- archive SHA-256:
  `b23d70deaa879b5c2d486ed3316f7eaa53e84acf6fc9cc747de152450d401489`;
- Git-stable closed-tree SHA-256 after removing the archive's seven empty
  directories:
  `521e2ef7605386b8da70aa3d6c3d135b344ee319c4b5a280470f8c07265ace43`;
- canonical receipt:
  `ThirdParty/Zig/zig-0.16.0.receipt.json`; and
- canonical receipt SHA-256:
  `55f99da3a6d9cfed280b2dbbe2ec87776cc3dc28b7a5d71cab9adabc8f8bdc94`.

The receipt binds version `0.16.0`, root basename `zig-0.16.0`, executable
path `zig`, 19,546 ordinary files, 1,278 nonempty directories, and 370,614,961
file bytes. Schema 2 records the `git-stable-nonempty-directories-v2`
algorithm. `Scripts/dependencies/zig_toolchain_receipt.py verify` re-hashes the
complete normalized tree before either Ghostty builder accepts it; the immutable
archive checksum separately anchors the original distribution bytes.

The toolchain is not linked into MacScope. It is invoked only to compile
repository-owned Ghostty sources into an explicit external work root. Normal
builds perform no download or package resolution.

The complete upstream MIT license is retained at
`ThirdParty/Zig/zig-0.16.0/LICENSE`. There are no local Zig patches.
