# reconstruction-c-sample

The reconstruction F target (profile `arm64-c-u32-saturating-increment-v1`): `candidate.c` and
`harness.c` are the production original source and harness, and `original-arm64` (33,656 B,
sha256 `e4aaf1e8...3ff0`) is the binary production original preparation built on 2026-10-08.

## Rebuild difference (traced 2026-10-12, Xcode 27.2 / macOS SDK 27.2)

`build.sh` reproduces the production compile argv. A rebuild is byte-identical except for 48 bytes
(`cmp -l` reports 47 or 48, because a changed byte can coincide):

| Offset | Bytes | What |
| --- | --- | --- |
| `0x380`-`0x38f` | 16 | `LC_UUID` |
| `0x8256`-`0x8275` | 32 | the CodeDirectory hash slot of page 0 in the linker ad-hoc signature (page 0 holds `LC_UUID`) |

Cause: production compiles and links in one `clang` invocation, so the driver writes the objects to
randomly named temporaries (`$TMPDIR/candidate-XXXXXX.o`) and ld64 folds those paths into the
`LC_UUID` it derives. A new UUID changes page 0, so the signature's page-0 hash changes with it.
Everything else (load commands, `LC_BUILD_VERSION`, segments, code, strings, the signature
identifier `candidate`) is identical. Two rebuilds differ from each other by the same 48 bytes;
compiling to fixed object paths and linking separately makes the UUID stable, but that is not
the production argv and gives a different UUID from the checked-in one.

Decision: the checked-in `original-arm64` is canonical. Tests pin its bytes and SHA-256; the
production loopback test rebuilds the original on every run and prints whether it matches
(`RECON_LOOPBACK_ORIGINAL ... identical=`), which is expected to be `false` for this reason only.
Name the output `candidate` (as production does) when comparing: another file name changes the
signature identifier and the CodeDirectory, which adds about 260 more differing bytes.
